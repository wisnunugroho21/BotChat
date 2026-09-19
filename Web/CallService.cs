using MongoDB.Driver;

namespace Standalone.Chat;

// Admission is serialized for the supported single-API deployment.
public sealed class CallService(ChatStore db, ChatService chat, Notifications notifications)
{
    private readonly SemaphoreSlim gate = new(1, 1);
    public async Task<Call> Start(string uid, string id, bool video)
    {
        await gate.WaitAsync();
        try
        {
            var c = await chat.Member(uid, id); var p = await chat.Profile(uid);
            ChatService.Require(c.Members.Count >= 2 && c.Members.Count <= 6, "Calls support 2–6 members.");
            await Expire();
            var active = await db.Calls.Find(x => x.Members.Any(m => c.Members.Contains(m)) && x.EndedAt == null).ToListAsync();
            var busy = active.Any(x => x.Joined.Intersect(c.Members).Any() || x.Status == "Ringing" && x.Members.Except(x.Declined).Intersect(c.Members).Any());
            ChatService.Require(!busy, "A participant is already in a call.", 409);
            var call = new Call { ConversationId = id, CallerId = uid, CallerName = p.Name, Video = video, Members = c.Members, Joined = [uid] };
            await db.Calls.InsertOneAsync(call);
            await notifications.Event(c.Members, "CallChanged", call);
            foreach (var recipient in c.Members.Where(x => x != uid))
                await notifications.Push(recipient, p.Name, video ? "Incoming video call" : "Incoming voice call", new() { ["type"] = "call", ["callId"] = call.Id, ["conversationId"] = id, ["callerName"] = p.Name, ["video"] = video ? "true" : "false", ["expiresAt"] = call.CreatedAt.AddSeconds(40).ToString("O") });
            return call;
        }
        finally { gate.Release(); }
    }
    public async Task<Call> Get(string uid, string id)
    {
        await Expire();
        var call = await db.Calls.Find(x => x.Id == id && x.Members.Contains(uid)).FirstOrDefaultAsync()
            ?? throw new ChatException(404, "Call unavailable.");
        await chat.Member(uid, call.ConversationId);
        return call;
    }
    public async Task<Call> Respond(string uid, string id, string action)
    {
        await gate.WaitAsync();
        try
        {
            var call = await Get(uid, id);
            if (call.EndedAt is not null) return call;
            if (action == "native-decline")
            {
                if (call.Joined.Contains(uid) || call.Declined.Contains(uid)) return call;
                action = "decline";
            }
            ChatService.Require(action is "join" or "leave" or "decline", "Invalid call action.");
            if (action == "join")
            {
                call.Declined.Remove(uid);
                if (!call.Joined.Contains(uid)) call.Joined.Add(uid);
                call.Status = "Active"; call.AnsweredAt ??= DateTime.UtcNow;
            }
            else
            {
                call.Joined.Remove(uid);
                if (!call.Declined.Contains(uid)) call.Declined.Add(uid);
                // A declined group invitation does not hang up the other participants.
                if (call.Members.Count == 2 || uid == call.CallerId && call.Status == "Ringing" || call.Joined.Count == 0 || call.Status == "Active" && call.Joined.Count < 2)
                { call.EndedAt = DateTime.UtcNow; call.Status = action == "decline" ? "Declined" : "Ended"; }
            }
            await db.Calls.ReplaceOneAsync(x => x.Id == id, call);
            await notifications.Event(call.Members, "CallChanged", call);
            await CancelRinging(call, call.EndedAt is not null ? call.Members : [uid]);
            return call;
        }
        finally { gate.Release(); }
    }
    public async Task ValidateSignal(string uid, string id, string recipient)
    {
        var call = await Get(uid, id);
        await chat.Member(recipient, call.ConversationId);
        ChatService.Require(call.EndedAt is null && call.Joined.Contains(uid) && call.Joined.Contains(recipient) && uid != recipient, "Call participant unavailable.", 403);
    }
    public async Task Expire()
    {
        var cutoff = DateTime.UtcNow.AddSeconds(-40);
        var abandoned = DateTime.UtcNow.AddHours(-4);
        var expired = await db.Calls.Find(x => x.EndedAt == null && (x.Status == "Ringing" && x.CreatedAt < cutoff || x.CreatedAt < abandoned)).ToListAsync();
        foreach (var call in expired)
        {
            var oldStatus = call.Status;
            call.Status = "Missed"; call.EndedAt = DateTime.UtcNow;
            var result = await db.Calls.ReplaceOneAsync(x => x.Id == call.Id && x.Status == oldStatus && x.EndedAt == null, call);
            if (result.ModifiedCount > 0)
            {
                await notifications.Event(call.Members, "CallChanged", call);
                await CancelRinging(call, call.Members);
            }
        }
    }
    private async Task CancelRinging(Call call, IEnumerable<string> members)
    {
        foreach (var uid in members)
            await notifications.Push(uid, "", "", new() { ["type"] = "call_cancel", ["callId"] = call.Id });
    }
}
