using System.Security.Claims;
using System.Security.Cryptography;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using MongoDB.Bson;
using MongoDB.Driver;

namespace Standalone.Chat;

[ApiController, Authorize, Route("api")]
public sealed class ChatController(ChatService chat, ChatStore db, Presence presence, CallService calls) : ControllerBase
{
    private string Uid => User.FindFirstValue(ClaimTypes.NameIdentifier)!;
    [HttpGet("me")] public Task<Profile> Me() => chat.Profile(Uid);
    [HttpPut("me")] public Task<Profile> SaveProfile(ProfileInput input) => chat.SaveProfile(Uid, input);
    [HttpGet("users")] public async Task<object> Users(string? q, string? after)
    {
        await chat.Profile(Uid);
        var f = Builders<Profile>.Filter.Ne(x => x.Id, Uid);
        if (!string.IsNullOrWhiteSpace(q))
        {
            ChatService.Require(q.Length <= 100, "Search is too long.");
            var regex = new BsonRegularExpression(System.Text.RegularExpressions.Regex.Escape(q), "i");
            f &= Builders<Profile>.Filter.Regex(x => x.Name, regex) | Builders<Profile>.Filter.Regex(x => x.Username, regex);
        }
        if (after is not null) f &= Builders<Profile>.Filter.Gt(x => x.Id, after);
        var items = await db.Profiles.Find(f).SortBy(x => x.Id).Limit(51).ToListAsync();
        var more = items.Count > 50; if (more) items.RemoveAt(50);
        return new { Items = items.Select(x => new { x.Id, x.Name, x.Username, x.LastSeen, Online = presence.Online(x.Id) }), NextCursor = more ? items[^1].Id : null };
    }
    [HttpGet("conversations")] public Task<List<object>> Conversations() => chat.List(Uid);
    [HttpPatch("conversations/{id}/preferences")] public Task Preferences(string id, ConversationPreferences input) => chat.Preferences(Uid, id, input);
    [HttpGet("conversations/{id}/pins")] public Task<List<Message>> Pins(string id) => chat.Pins(Uid, id);
    [HttpPut("conversations/{id}/messages/{messageId}/pin")] public Task Pin(string id, string messageId, PinInput input) => chat.Pin(Uid, id, messageId, input.Pinned);
    [HttpPost("conversations")] public Task<Conversation> Create(ConversationInput input) => chat.Create(Uid, input);
    [HttpGet("conversations/{id}/members")] public Task<List<Profile>> Members(string id) => chat.Members(Uid, id);
    [HttpPut("conversations/{id}")] public Task<Conversation> Edit(string id, GroupInput input) => chat.Edit(Uid, id, input);
    [HttpPost("conversations/{id}/leave")] public Task Leave(string id) => chat.Leave(Uid, id);
    [HttpDelete("conversations/{id}")] public Task Clear(string id, bool hide = false) => chat.Clear(Uid, id, hide);
    [HttpGet("conversations/{id}/messages")] public Task<Page<Message>> History(string id, string? before, string? q) => chat.History(Uid, id, before, q);
    [HttpGet("messages/search")] public Task<Page<Message>> Search(string q, string? conversationId, string? before) => chat.Search(Uid, q, conversationId, before);
    [HttpPost("conversations/{id}/messages")] public Task<Message> Send(string id, SendInput input) => chat.Send(Uid, id, input);
    [HttpDelete("conversations/{id}/messages/{messageId}")] public Task Delete(string id, string messageId) => chat.Delete(Uid, id, messageId);
    [HttpPost("conversations/{id}/read/{messageId}")] public Task Read(string id, string messageId) => chat.Read(Uid, id, messageId);
    [HttpPost("broadcasts")] public async Task<object> Broadcast(BroadcastInput input)
    {
        ChatService.ValidateSend(new(input.ClientMessageId, input.Text));
        ChatService.Require(input.Recipients.Count is >= 1 and <= 49, "Choose 1–49 recipients.");
        var results = new List<object>();
        foreach (var recipient in input.Recipients.Distinct())
        {
            try
            {
                var c = await chat.Create(Uid, new(null, [recipient]));
                var m = await chat.Send(Uid, c.Id, new(input.ClientMessageId, input.Text));
                results.Add(new { Recipient = recipient, Message = m, Error = (string?)null });
            }
            catch (ChatException ex) { results.Add(new { Recipient = recipient, Message = (Message?)null, Error = ex.Message }); }
        }
        return results;
    }

    [HttpPost("conversations/{id}/attachments"), RequestSizeLimit(26 * 1024 * 1024)]
    public async Task<Message> Upload(string id, IFormFile file, [FromForm] string clientMessageId, [FromForm] string? replyToMessageId = null)
    {
        await chat.Member(Uid, id);
        ChatService.Require(Guid.TryParse(clientMessageId, out _), "A client UUID is required.");
        ChatService.Require(file.Length is > 0 and <= 25 * 1024 * 1024, "Choose a file between 1 byte and 25 MB.");
        var name = Path.GetFileName(file.FileName.Replace('\\', '/'));
        name = new string(name.Where(c => !char.IsControl(c)).ToArray());
        ChatService.Require(name.Length is >= 1 and <= 180, "Invalid file name.");
        // Keep files private in GridFS; downloads always re-check current membership.
        await using var content = new MemoryStream();
        await file.CopyToAsync(content, HttpContext.RequestAborted);
        ChatService.Require(content.Length == file.Length, "Upload incomplete.");
        var hash = Convert.ToHexString(SHA256.HashData(content.GetBuffer().AsSpan(0, (int)content.Length)));
        var mime = file.ContentType.ToLowerInvariant();
        if (!System.Text.RegularExpressions.Regex.IsMatch(mime, "^[a-z0-9.+-]+/[a-z0-9.+-]+$")) mime = "application/octet-stream";
        var existing = await db.Messages.Find(x => x.ConversationId == id && x.SenderId == Uid && x.ClientMessageId == clientMessageId).FirstOrDefaultAsync();
        if (existing is not null) return await chat.Send(Uid, id, new(clientMessageId, name, replyToMessageId), new(existing.Attachment?.Id ?? "", name, mime, content.Length, hash));
        if (replyToMessageId is not null)
            ChatService.Require(await db.Messages.Find(x => x.Id == replyToMessageId && x.ConversationId == id && !x.Deleted).AnyAsync(), "Quoted message unavailable.", 404);
        content.Position = 0;
        var fileId = await db.Files.UploadFromStreamAsync(name, content, cancellationToken: HttpContext.RequestAborted);
        var result = await chat.Send(Uid, id, new(clientMessageId, name, replyToMessageId), new(fileId.ToString(), name, mime, content.Length, hash));
        // A concurrent identical retry may have won the unique message index.
        if (result.Attachment?.Id != fileId.ToString()) await db.Files.DeleteAsync(fileId);
        return result;
    }
    [HttpGet("conversations/{id}/attachments/{fileId}")]
    public async Task<IActionResult> Download(string id, string fileId)
    {
        await chat.Member(Uid, id);
        ChatService.Require(ObjectId.TryParse(fileId, out var parsed), "Invalid attachment.");
        var m = await db.Messages.Find(x => x.ConversationId == id && x.Attachment != null && x.Attachment.Id == fileId && !x.Deleted).FirstOrDefaultAsync();
        if (m?.Attachment is null) return NotFound();
        Response.Headers.XContentTypeOptions = "nosniff";
        return File(await db.Files.OpenDownloadStreamAsync(parsed), m.Attachment.MimeType, m.Attachment.FileName, enableRangeProcessing: true);
    }
    [HttpPut("devices")] public async Task Register(TokenInput input)
    {
        await chat.Profile(Uid);
        ChatService.Require(input.Token.Length is >= 20 and <= 4096, "Invalid device token.");
        var id = Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(input.Token)));
        await db.Devices.ReplaceOneAsync(x => x.Id == id, new Device { Id = id, UserId = Uid, Token = input.Token }, new ReplaceOptions { IsUpsert = true });
    }
    [HttpDelete("devices")] public Task RemoveToken(TokenInput input) => db.Devices.DeleteManyAsync(x => x.UserId == Uid && x.Token == input.Token);
    [HttpPost("conversations/{id}/calls")] public Task<Call> StartCall(string id, CallInput input) => calls.Start(Uid, id, input.Video);
    [HttpGet("calls")] public async Task<List<Call>> HistoryCalls()
    { await calls.Expire(); return await db.Calls.Find(x => x.Members.Contains(Uid)).SortByDescending(x => x.CreatedAt).Limit(100).ToListAsync(); }
    [HttpGet("calls/{id}")] public Task<Call> GetCall(string id) => calls.Get(Uid, id);
    [HttpPost("calls/{id}/{operation}")] public Task<Call> Respond(string id, string operation) => calls.Respond(Uid, id, operation);
    // A registered device can only decline its own outstanding invitation.
    // This supports Android notification actions while Flutter is terminated.
    [AllowAnonymous, HttpPost("calls/{id}/native-decline")]
    public async Task<Call> NativeDecline(string id, NativeDeclineInput input)
    {
        ChatService.Require(input.DeviceToken.Length is >= 20 and <= 4096, "Invalid device token.", 401);
        var hash = Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(input.DeviceToken)));
        var device = await db.Devices.Find(x => x.Id == hash).FirstOrDefaultAsync()
            ?? throw new ChatException(401, "Device is no longer registered.");
        return await calls.Respond(device.UserId, id, "native-decline");
    }
}

public sealed record NativeDeclineInput(string DeviceToken);
