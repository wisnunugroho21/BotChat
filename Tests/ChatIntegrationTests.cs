using System.Net;
using System.Net.Http.Json;
using System.Security.Claims;
using System.Text.Encodings.Web;
using System.Text.Json;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using Microsoft.AspNetCore.SignalR.Client;
using Microsoft.AspNetCore.Http.Connections;
using MongoDB.Driver;
using Standalone.Chat;
using Xunit;

namespace Standalone.Tests;

// Test identity exists only in this test assembly. Production always validates Firebase JWTs.
public sealed class TestAuthentication(IOptionsMonitor<AuthenticationSchemeOptions> options, ILoggerFactory logger, UrlEncoder encoder)
    : AuthenticationHandler<AuthenticationSchemeOptions>(options, logger, encoder)
{
    protected override Task<AuthenticateResult> HandleAuthenticateAsync()
    {
        if (!Request.Headers.TryGetValue("X-Test-User", out var uid)) return Task.FromResult(AuthenticateResult.NoResult());
        var identity = new ClaimsIdentity([new Claim(ClaimTypes.NameIdentifier, uid.ToString())], Scheme.Name);
        return Task.FromResult(AuthenticateResult.Success(new AuthenticationTicket(new ClaimsPrincipal(identity), Scheme.Name)));
    }
}
public sealed class Factory : WebApplicationFactory<Program>
{
    public string Database { get; } = "standalone_chat_test_" + Guid.NewGuid().ToString("N");
    public string Connection { get; } = Environment.GetEnvironmentVariable("CHAT_TEST_MONGO") ?? "mongodb://localhost:27017";
    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseSetting("Firebase:ProjectId", "standalone-test");
        builder.ConfigureAppConfiguration((_, config) => config.AddInMemoryCollection(new Dictionary<string, string?> {
            ["Mongo:ConnectionString"] = Connection, ["Mongo:Database"] = Database,
            ["Firebase:ProjectId"] = "standalone-test", ["Firebase:EnablePush"] = "false" }));
        builder.ConfigureServices(services => services.AddAuthentication(o => { o.DefaultAuthenticateScheme = "Test"; o.DefaultChallengeScheme = "Test"; })
            .AddScheme<AuthenticationSchemeOptions, TestAuthentication>("Test", _ => { }));
    }
    public HttpClient Client(string? uid)
    {
        var client = CreateClient(); if (uid is not null) client.DefaultRequestHeaders.Add("X-Test-User", uid); return client;
    }
    protected override void Dispose(bool disposing)
    {
        base.Dispose(disposing);
        if (disposing) new MongoClient(Connection).DropDatabase(Database);
    }
}

public sealed class ChatIntegrationTests : IClassFixture<Factory>
{
    private readonly Factory factory;
    public ChatIntegrationTests(Factory factory) => this.factory = factory;
    private async Task<HttpClient> User(string name)
    {
        var id = name + Guid.NewGuid().ToString("N")[..8];
        var client = factory.Client(id);
        (await client.PutAsJsonAsync("/api/me", new ProfileInput(id, name))).EnsureSuccessStatusCode();
        return client;
    }
    private static string Uid(HttpClient c) => c.DefaultRequestHeaders.GetValues("X-Test-User").Single();
    private static async Task<Conversation> Direct(HttpClient a, HttpClient b) => (await (await a.PostAsJsonAsync("/api/conversations", new ConversationInput(null, [Uid(b)]))).Content.ReadFromJsonAsync<Conversation>())!;
    private static async Task<Message> Send(HttpClient a, string id, string text, string? key = null, string? reply = null)
    {
        var response = await a.PostAsJsonAsync($"/api/conversations/{id}/messages", new SendInput(key ?? Guid.NewGuid().ToString(), text, reply));
        response.EnsureSuccessStatusCode(); return (await response.Content.ReadFromJsonAsync<Message>())!;
    }
    [Fact] public async Task Anonymous_cannot_read_directory_or_chat()
    {
        using var client = factory.Client(null);
        Assert.Equal(HttpStatusCode.Unauthorized, (await client.GetAsync("/api/users")).StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized, (await client.GetAsync("/api/conversations")).StatusCode);
    }
    [Fact] public async Task Conversation_preferences_are_private_persistent_and_independent_of_reads()
    {
        using var a = await User("alice"); using var b = await User("bob"); using var e = await User("eve"); var c = await Direct(a, b);
        (await a.PatchAsJsonAsync($"/api/conversations/{c.Id}/preferences", new ConversationPreferences(true, true, true))).EnsureSuccessStatusCode();
        var m = await Send(b, c.Id, "New message while archived");
        (await a.PostAsync($"/api/conversations/{c.Id}/read/{m.Id}", null)).EnsureSuccessStatusCode();
        var own = (await a.GetFromJsonAsync<JsonElement[]>("/api/conversations"))!.Single();
        Assert.True(own.GetProperty("pinned").GetBoolean()); Assert.True(own.GetProperty("muted").GetBoolean()); Assert.True(own.GetProperty("archived").GetBoolean());
        var peer = (await b.GetFromJsonAsync<JsonElement[]>("/api/conversations"))!.Single();
        Assert.False(peer.GetProperty("pinned").GetBoolean()); Assert.False(peer.GetProperty("muted").GetBoolean()); Assert.False(peer.GetProperty("archived").GetBoolean());
        foreach (var read in peer.GetProperty("reads").EnumerateArray()) Assert.False(read.TryGetProperty("muted", out _));
        Assert.Equal(HttpStatusCode.NotFound, (await e.PatchAsJsonAsync($"/api/conversations/{c.Id}/preferences", new ConversationPreferences(Muted: true))).StatusCode);
        (await a.PatchAsJsonAsync($"/api/conversations/{c.Id}/preferences", new ConversationPreferences(Archived: false))).EnsureSuccessStatusCode();
        var state = await factory.Services.GetRequiredService<ChatService>().State(Uid(a), c.Id);
        Assert.True(state.Muted); Assert.True(state.Pinned); Assert.False(state.Archived);
    }
    [Fact] public async Task Message_pins_enforce_membership_privacy_clear_boundaries_and_deletion()
    {
        using var a = await User("alice"); using var b = await User("bob"); using var e = await User("eve"); var c = await Direct(a, b); var other = await Direct(a, e);
        var m = await Send(b, c.Id, "Keep this"); var unrelated = await Send(e, other.Id, "Other conversation");
        string Path(string cid, string mid) => $"/api/conversations/{cid}/messages/{mid}/pin";
        (await a.PutAsJsonAsync(Path(c.Id, m.Id), new PinInput(true))).EnsureSuccessStatusCode();
        (await a.PutAsJsonAsync(Path(c.Id, m.Id), new PinInput(true))).EnsureSuccessStatusCode();
        Assert.Single((await a.GetFromJsonAsync<List<Message>>($"/api/conversations/{c.Id}/pins"))!);
        Assert.Empty((await b.GetFromJsonAsync<List<Message>>($"/api/conversations/{c.Id}/pins"))!);
        Assert.Equal(HttpStatusCode.NotFound, (await e.GetAsync($"/api/conversations/{c.Id}/pins")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await a.PutAsJsonAsync(Path(c.Id, unrelated.Id), new PinInput(true))).StatusCode);
        (await a.DeleteAsync($"/api/conversations/{c.Id}")).EnsureSuccessStatusCode();
        Assert.Empty((await a.GetFromJsonAsync<List<Message>>($"/api/conversations/{c.Id}/pins"))!);
        Assert.Equal(HttpStatusCode.NotFound, (await a.PutAsJsonAsync(Path(c.Id, m.Id), new PinInput(true))).StatusCode);
        (await b.PutAsJsonAsync(Path(c.Id, m.Id), new PinInput(true))).EnsureSuccessStatusCode();
        (await b.DeleteAsync($"/api/conversations/{c.Id}/messages/{m.Id}")).EnsureSuccessStatusCode();
        Assert.Empty((await factory.Services.GetRequiredService<ChatService>().State(Uid(b), c.Id)).PinnedMessageIds);
    }
    [Fact] public async Task Native_decline_requires_registered_invited_device_and_ignores_answered_calls()
    {
        using var a = await User("alice"); using var b = await User("bob"); using var outsider = await User("eve");
        using var native = factory.Client(null);
        var token = Guid.NewGuid().ToString(); var otherToken = Guid.NewGuid().ToString();
        (await b.PutAsJsonAsync("/api/devices", new TokenInput(token))).EnsureSuccessStatusCode();
        (await outsider.PutAsJsonAsync("/api/devices", new TokenInput(otherToken))).EnsureSuccessStatusCode();
        var c = await Direct(a, b);
        var call = (await (await a.PostAsJsonAsync($"/api/conversations/{c.Id}/calls", new CallInput(false))).Content.ReadFromJsonAsync<Call>())!;
        var url = $"/api/calls/{call.Id}/native-decline";
        Assert.Equal(HttpStatusCode.Unauthorized, (await native.PostAsJsonAsync(url, new NativeDeclineInput(Guid.NewGuid().ToString()))).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await native.PostAsJsonAsync(url, new NativeDeclineInput(otherToken))).StatusCode);
        (await b.PostAsync($"/api/calls/{call.Id}/join", null)).EnsureSuccessStatusCode();
        var answered = await (await native.PostAsJsonAsync(url, new NativeDeclineInput(token))).Content.ReadFromJsonAsync<Call>();
        Assert.Null(answered!.EndedAt); Assert.Contains(Uid(b), answered.Joined);
        (await b.PostAsync($"/api/calls/{call.Id}/leave", null)).EnsureSuccessStatusCode();
        var next = (await (await a.PostAsJsonAsync($"/api/conversations/{c.Id}/calls", new CallInput(false))).Content.ReadFromJsonAsync<Call>())!;
        var declined = await (await native.PostAsJsonAsync($"/api/calls/{next.Id}/native-decline", new NativeDeclineInput(token))).Content.ReadFromJsonAsync<Call>();
        Assert.Equal("Declined", declined!.Status);
        using var revoke = new HttpRequestMessage(HttpMethod.Delete, "/api/devices") { Content = JsonContent.Create(new TokenInput(token)) };
        (await b.SendAsync(revoke)).EnsureSuccessStatusCode();
        Assert.Equal(HttpStatusCode.Unauthorized, (await native.PostAsJsonAsync(url, new NativeDeclineInput(token))).StatusCode);
    }
    [Fact] public async Task Concurrent_direct_creation_and_send_retries_are_unique()
    {
        using var a = await User("alice"); using var b = await User("bob");
        var cs = await Task.WhenAll(Enumerable.Range(0, 8).Select(_ => Direct(a, b)));
        Assert.Single(cs.Select(x => x.Id).Distinct());
        var key = Guid.NewGuid().ToString();
        var messages = await Task.WhenAll(Enumerable.Range(0, 8).Select(_ => Send(a, cs[0].Id, "hello", key)));
        Assert.Single(messages.Select(x => x.Id).Distinct());
        var mismatch = await a.PostAsJsonAsync($"/api/conversations/{cs[0].Id}/messages", new SendInput(key, "changed"));
        Assert.Equal(HttpStatusCode.Conflict, mismatch.StatusCode);
    }
    [Fact] public async Task Membership_and_reply_scope_are_enforced()
    {
        using var a = await User("alice"); using var b = await User("bob"); using var outsider = await User("eve");
        var c = await Direct(a, b); var other = await Direct(a, outsider);
        var m = await Send(a, c.Id, "private");
        Assert.Equal(HttpStatusCode.NotFound, (await outsider.GetAsync($"/api/conversations/{c.Id}/messages")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await a.PostAsJsonAsync($"/api/conversations/{other.Id}/messages", new SendInput(Guid.NewGuid().ToString(), "quote", m.Id))).StatusCode);
        var reply = await Send(b, c.Id, "answer", reply: m.Id);
        Assert.Equal("private", reply.Reply!.Preview);
        await a.DeleteAsync($"/api/conversations/{c.Id}/messages/{m.Id}");
        var history = await b.GetFromJsonAsync<Page<Message>>($"/api/conversations/{c.Id}/messages");
        Assert.Single(history!.Items); Assert.Equal("private", history.Items[0].Reply!.Preview);
    }
    [Fact] public async Task History_pages_and_literal_search_do_not_leak_cursors()
    {
        using var a = await User("alice"); using var b = await User("bob"); using var e = await User("eve");
        var c = await Direct(a, b); var other = await Direct(a, e);
        for (var i = 0; i < 55; i++) await Send(a, c.Id, $"message {i} literal .* token");
        var one = await a.GetFromJsonAsync<Page<Message>>($"/api/conversations/{c.Id}/messages");
        Assert.Equal(50, one!.Items.Count); Assert.NotNull(one.NextCursor);
        var two = await a.GetFromJsonAsync<Page<Message>>($"/api/conversations/{c.Id}/messages?before={one.NextCursor}");
        Assert.Equal(5, two!.Items.Count); Assert.Null(two.NextCursor);
        Assert.Equal(55, one.Items.Concat(two.Items).Select(x => x.Id).Distinct().Count());
        Assert.Equal(HttpStatusCode.BadRequest, (await a.GetAsync($"/api/conversations/{other.Id}/messages?before={one.NextCursor}")).StatusCode);
        var search = await b.GetFromJsonAsync<Page<Message>>("/api/messages/search?q=" + Uri.EscapeDataString(".*"));
        Assert.Equal(50, search!.Items.Count);
        var hidden = await e.GetFromJsonAsync<Page<Message>>("/api/messages/search?q=literal"); Assert.Empty(hidden!.Items);
    }
    [Fact] public async Task Owner_management_removed_member_and_mentions()
    {
        using var a = await User("alice"); using var b = await User("bob"); using var e = await User("eve");
        var c = (await (await a.PostAsJsonAsync("/api/conversations", new ConversationInput("Dispatch", [Uid(b), Uid(e)]))).Content.ReadFromJsonAsync<Conversation>())!;
        var m = await Send(a, c.Id, $"Hi @{Uid(b)} and email@{Uid(e)}");
        Assert.Contains(Uid(b), m.Mentions); Assert.DoesNotContain(Uid(e), m.Mentions);
        Assert.Equal(HttpStatusCode.Forbidden, (await b.PutAsJsonAsync($"/api/conversations/{c.Id}", new GroupInput("Bad", [Uid(a), Uid(b)], 0))).StatusCode);
        (await a.PutAsJsonAsync($"/api/conversations/{c.Id}", new GroupInput("Dispatch", [Uid(a), Uid(b)], 0))).EnsureSuccessStatusCode();
        Assert.Equal(HttpStatusCode.NotFound, (await e.GetAsync($"/api/conversations/{c.Id}/messages")).StatusCode);
        Assert.Equal(HttpStatusCode.Conflict, (await a.PutAsJsonAsync($"/api/conversations/{c.Id}", new GroupInput("Stale", [Uid(a), Uid(b)], 0))).StatusCode);
    }
    [Fact] public async Task Read_receipts_are_monotonic_and_clear_is_private()
    {
        using var a = await User("alice"); using var b = await User("bob"); var c = await Direct(a, b);
        var m1 = await Send(a, c.Id, "one"); await Task.Delay(5); var m2 = await Send(a, c.Id, "two");
        (await b.PostAsync($"/api/conversations/{c.Id}/read/{m2.Id}", null)).EnsureSuccessStatusCode();
        (await b.PostAsync($"/api/conversations/{c.Id}/read/{m1.Id}", null)).EnsureSuccessStatusCode();
        var db = factory.Services.GetRequiredService<ChatStore>();
        var read = await db.Reads.Find(x => x.UserId == Uid(b) && x.ConversationId == c.Id).FirstAsync();
        Assert.Equal(m2.CreatedAt, read.ReadAt);
        (await b.DeleteAsync($"/api/conversations/{c.Id}")).EnsureSuccessStatusCode();
        Assert.Empty((await b.GetFromJsonAsync<Page<Message>>($"/api/conversations/{c.Id}/messages"))!.Items);
        Assert.Equal(2, (await a.GetFromJsonAsync<Page<Message>>($"/api/conversations/{c.Id}/messages"))!.Items.Count);
    }
    [Fact] public async Task Attachment_retries_and_downloads_are_authenticated()
    {
        using var a = await User("alice"); using var b = await User("bob"); using var e = await User("eve"); var c = await Direct(a, b);
        var key = Guid.NewGuid().ToString();
        async Task<HttpResponseMessage> Upload(string content)
        {
            var form = new MultipartFormDataContent { { new StringContent(key), "clientMessageId" }, { new ByteArrayContent(System.Text.Encoding.UTF8.GetBytes(content)), "file", "note.txt" } };
            return await a.PostAsync($"/api/conversations/{c.Id}/attachments", form);
        }
        var response = await Upload("hello"); response.EnsureSuccessStatusCode(); var m = (await response.Content.ReadFromJsonAsync<Message>())!;
        var retry = await Upload("hello"); retry.EnsureSuccessStatusCode(); Assert.Equal(m.Id, (await retry.Content.ReadFromJsonAsync<Message>())!.Id);
        Assert.Equal(HttpStatusCode.Conflict, (await Upload("changed")).StatusCode);
        var path = $"/api/conversations/{c.Id}/attachments/{m.Attachment!.Id}";
        Assert.Equal("hello", await b.GetStringAsync(path));
        Assert.Equal(HttpStatusCode.NotFound, (await e.GetAsync(path)).StatusCode);
    }
    [Fact] public async Task Calls_enforce_admission_and_participants()
    {
        using var a = await User("alice"); using var b = await User("bob"); using var e = await User("eve"); var c = await Direct(a, b);
        var response = await a.PostAsJsonAsync($"/api/conversations/{c.Id}/calls", new CallInput(false)); response.EnsureSuccessStatusCode();
        var call = (await response.Content.ReadFromJsonAsync<Call>())!;
        Assert.Equal(HttpStatusCode.Conflict, (await b.PostAsJsonAsync($"/api/conversations/{c.Id}/calls", new CallInput(false))).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await e.PostAsync($"/api/calls/{call.Id}/join", null)).StatusCode);
        (await b.PostAsync($"/api/calls/{call.Id}/join", null)).EnsureSuccessStatusCode();
        await factory.Services.GetRequiredService<CallService>().ValidateSignal(Uid(a), call.Id, Uid(b));
        (await a.PostAsync($"/api/calls/{call.Id}/leave", null)).EnsureSuccessStatusCode();
        Assert.NotNull((await b.GetFromJsonAsync<Call>($"/api/calls/{call.Id}"))!.EndedAt);
    }
    [Theory]
    [InlineData("image/png", "photo.png", "Image", "Photo")]
    [InlineData("video/mp4", "clip.mp4", "Video", "Video")]
    [InlineData("audio/mp4", "voice.m4a", "Audio", "Voice note")]
    [InlineData("application/pdf", "document.pdf", "File", "File")]
    public async Task Quoted_replies_work_between_text_and_all_attachment_types(string mime, string name, string type, string label)
    {
        using var a = await User("alice"); using var b = await User("bob"); var c = await Direct(a, b);
        var text = await Send(b, c.Id, "Please review");
        async Task<HttpResponseMessage> Upload(string key, string? reply, string conversation)
        {
            using var file = new ByteArrayContent([1, 2, 3]);
            file.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue(mime);
            using var form = new MultipartFormDataContent { { new StringContent(key), "clientMessageId" }, { file, "file", name } };
            if (reply is not null) form.Add(new StringContent(reply), "replyToMessageId");
            return await a.PostAsync($"/api/conversations/{conversation}/attachments", form);
        }
        var response = await Upload(Guid.NewGuid().ToString(), text.Id, c.Id); response.EnsureSuccessStatusCode();
        var source = (await response.Content.ReadFromJsonAsync<Message>())!;
        Assert.Equal(type, source.Type); Assert.Equal("Please review", source.Reply!.Preview);
        var textReply = await Send(b, c.Id, "Reviewed", reply: source.Id);
        Assert.Equal(type, textReply.Reply!.Type); Assert.Equal($"{label} · {name}", textReply.Reply.Preview);
        var key = Guid.NewGuid().ToString();
        var attachedReply = (await (await Upload(key, source.Id, c.Id)).Content.ReadFromJsonAsync<Message>())!;
        Assert.Equal(textReply.Reply, attachedReply.Reply);
        Assert.Equal(HttpStatusCode.Conflict, (await Upload(key, text.Id, c.Id)).StatusCode);
        using var outsider = await User("eve"); var other = await Direct(a, outsider);
        Assert.Equal(HttpStatusCode.NotFound, (await Upload(Guid.NewGuid().ToString(), source.Id, other.Id)).StatusCode);
        (await a.DeleteAsync($"/api/conversations/{c.Id}/messages/{source.Id}")).EnsureSuccessStatusCode();
        var retry = await Upload(key, source.Id, c.Id); retry.EnsureSuccessStatusCode();
        Assert.Equal(attachedReply.Id, (await retry.Content.ReadFromJsonAsync<Message>())!.Id);
        var history = await b.GetFromJsonAsync<Page<Message>>($"/api/conversations/{c.Id}/messages");
        Assert.Equal(textReply.Reply, history!.Items.Single(x => x.Id == attachedReply.Id).Reply);
        Assert.Equal(HttpStatusCode.NotFound, (await Upload(Guid.NewGuid().ToString(), source.Id, c.Id)).StatusCode);
    }

    [Fact] public async Task SignalR_delivers_to_recipient_and_other_sender_session()
    {
        using var a = await User("alice"); using var b = await User("bob"); var c = await Direct(a, b);
        HubConnection Connection(HttpClient client) => new HubConnectionBuilder().WithUrl("http://localhost/hubs/chat", options => {
            options.Transports = HttpTransportType.LongPolling;
            options.HttpMessageHandlerFactory = _ => factory.Server.CreateHandler();
            options.Headers["X-Test-User"] = Uid(client);
        }).Build();
        await using var senderSession = Connection(a); await using var recipient = Connection(b);
        var sent = new TaskCompletionSource<Message>(TaskCreationOptions.RunContinuationsAsynchronously);
        var received = new TaskCompletionSource<Message>(TaskCreationOptions.RunContinuationsAsynchronously);
        senderSession.On<Message>("MessageReceived", m => sent.TrySetResult(m));
        recipient.On<Message>("MessageReceived", m => received.TrySetResult(m));
        await senderSession.StartAsync(); await recipient.StartAsync();
        var saved = await Send(a, c.Id, "realtime");
        Assert.Equal(saved.Id, (await sent.Task.WaitAsync(TimeSpan.FromSeconds(5))).Id);
        Assert.Equal(saved.Id, (await received.Task.WaitAsync(TimeSpan.FromSeconds(5))).Id);
    }

    [Fact] public async Task Expired_call_and_removed_member_stop_active_calls()
    {
        using var a = await User("alice"); using var b = await User("bob"); using var e = await User("eve");
        var c = (await (await a.PostAsJsonAsync("/api/conversations", new ConversationInput("Team", [Uid(b), Uid(e)]))).Content.ReadFromJsonAsync<Conversation>())!;
        var db = factory.Services.GetRequiredService<ChatStore>();
        var expired = new Call { ConversationId = c.Id, CallerId = Uid(a), Members = c.Members, Joined = [Uid(a)], CreatedAt = DateTime.UtcNow.AddMinutes(-2) };
        await db.Calls.InsertOneAsync(expired);
        await factory.Services.GetRequiredService<CallService>().Expire();
        Assert.NotNull((await db.Calls.Find(x => x.Id == expired.Id).FirstAsync()).EndedAt);
        var active = (await (await a.PostAsJsonAsync($"/api/conversations/{c.Id}/calls", new CallInput(false))).Content.ReadFromJsonAsync<Call>())!;
        (await b.PostAsync($"/api/calls/{active.Id}/join", null)).EnsureSuccessStatusCode();
        (await a.PutAsJsonAsync($"/api/conversations/{c.Id}", new GroupInput("Team", [Uid(a), Uid(e)], 0))).EnsureSuccessStatusCode();
        Assert.NotNull((await db.Calls.Find(x => x.Id == active.Id).FirstAsync()).EndedAt);
    }
}
