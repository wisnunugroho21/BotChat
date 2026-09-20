using System.Collections.Concurrent;
using FirebaseAdmin.Messaging;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.SignalR;
using MongoDB.Driver;

namespace Standalone.Chat;

public sealed class Presence
{
    private readonly ConcurrentDictionary<string, string> connections = new();
    public void Add(string connection, string uid) => connections[connection] = uid;
    public void Remove(string connection) => connections.TryRemove(connection, out _);
    public bool Online(string uid) => connections.Values.Contains(uid);
}

public sealed class Notifications(ChatStore db, IHubContext<ChatHub> hub, IConfiguration config, ILogger<Notifications> log)
{
    public async Task Event(IEnumerable<string> users, string name, object payload)
    {
        try { await hub.Clients.Users(users.Distinct().ToList()).SendAsync(name, payload); }
        catch (Exception ex) { log.LogError(ex, "Realtime delivery failed for {Event}", name); }
    }
    public async Task Message(Conversation c, Message m)
    {
        await Event(c.Members, "MessageReceived", m);
        foreach (var uid in c.Members.Where(x => x != m.SenderId))
        {
            if (await db.Reads.Find(x => x.UserId == uid && x.ConversationId == c.Id && x.Muted).AnyAsync()) continue;
            await Push(uid, c.Type == "Group" ? c.Name : m.SenderName,
                m.Mentions.Contains(uid) ? $"{m.SenderName} mentioned you" : m.Attachment?.FileName ?? m.Text,
                new() { ["type"] = "message", ["conversationId"] = c.Id, ["messageId"] = m.Id });
        }
    }
    public async Task Push(string uid, string title, string body, Dictionary<string, string> data)
    {
        if (!config.GetValue<bool>("Firebase:EnablePush")) return;
        try
        {
            var devices = await db.Devices.Find(x => x.UserId == uid).ToListAsync();
            foreach (var device in devices)
            {
                try
                {
                    var call = data.GetValueOrDefault("type") == "call";
                    var cancel = data.GetValueOrDefault("type") == "call_cancel";
                    var preview = body.Length > 180 ? body[..180] : body;
                    await FirebaseMessaging.DefaultInstance.SendAsync(new FirebaseAdmin.Messaging.Message {
                        Token = device.Token, Notification = call || cancel ? null : new Notification { Title = title, Body = preview }, Data = data,
                        Android = new AndroidConfig { Priority = Priority.High, TimeToLive = call ? TimeSpan.FromSeconds(40) : null, Notification = call || cancel ? null : new AndroidNotification { ChannelId = "chat_messages", Tag = data.GetValueOrDefault("messageId") } },
                        Apns = new ApnsConfig { Aps = cancel ? new Aps { ContentAvailable = true } : new Aps { Sound = "default", Alert = call ? new ApsAlert { Title = title, Body = preview } : null } }
                    });
                }
                catch (FirebaseMessagingException ex) when (ex.MessagingErrorCode == MessagingErrorCode.Unregistered)
                { await db.Devices.DeleteOneAsync(x => x.Id == device.Id && x.Token == device.Token); }
            }
        }
        catch (Exception ex) { log.LogError(ex, "Push delivery failed for user {UserId}", uid); }
    }
}

[Authorize]
public sealed class ChatHub(ChatService chat, ChatStore db, Presence presence, CallService calls) : Hub
{
    private string Uid => Context.UserIdentifier ?? throw new HubException("Sign in first.");
    public override async Task OnConnectedAsync()
    {
        await chat.Profile(Uid);
        presence.Add(Context.ConnectionId, Uid);
        await PublishPresence(true);
        var conversations = await db.Conversations.Find(x => x.Members.Contains(Uid)).ToListAsync();
        foreach (var peer in conversations.SelectMany(x => x.Members).Distinct().Where(x => x != Uid))
            await Clients.Caller.SendAsync("PresenceChanged", new { UserId = peer, Online = presence.Online(peer) });
        await base.OnConnectedAsync();
    }
    public override async Task OnDisconnectedAsync(Exception? exception)
    {
        presence.Remove(Context.ConnectionId);
        if (!presence.Online(Uid))
        {
            await db.Profiles.UpdateOneAsync(x => x.Id == Uid, Builders<Profile>.Update.Set(x => x.LastSeen, DateTime.UtcNow));
            await PublishPresence(false);
        }
        await base.OnDisconnectedAsync(exception);
    }
    private async Task PublishPresence(bool online)
    {
        var cs = await db.Conversations.Find(x => x.Members.Contains(Uid)).ToListAsync();
        await Clients.Users(cs.SelectMany(x => x.Members).Distinct().ToList()).SendAsync("PresenceChanged", new { UserId = Uid, Online = online });
    }
    public async Task Typing(string conversationId)
    {
        var c = await chat.Member(Uid, conversationId);
        await Clients.Users(c.Members.Where(x => x != Uid).ToList()).SendAsync("Typing", new { ConversationId = conversationId, UserId = Uid });
    }
    public Task<Message> SendMessage(string conversationId, SendInput input) => chat.Send(Uid, conversationId, input);
    public async Task Signal(string callId, string recipientId, string kind, string payload)
    {
        ChatService.Require(kind is "offer" or "answer" or "candidate" && payload.Length <= 64000, "Invalid call signal.");
        await calls.ValidateSignal(Uid, callId, recipientId);
        await Clients.User(recipientId).SendAsync("CallSignal", new { CallId = callId, SenderId = Uid, Kind = kind, Payload = payload });
    }
}
