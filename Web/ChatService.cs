using System.Security.Cryptography;
using System.Text.RegularExpressions;
using MongoDB.Bson;
using MongoDB.Driver;

namespace Standalone.Chat;

public sealed class ChatService(ChatStore db, Notifications notifications)
{
    public static void Require(bool valid, string message, int status = 400)
    {
        if (!valid) throw new ChatException(status, message);
    }
    public async Task<Profile> Profile(string uid) => await db.Profiles.Find(x => x.Id == uid).FirstOrDefaultAsync()
        ?? throw new ChatException(409, "Complete your profile first.");

    public async Task<Profile> SaveProfile(string uid, ProfileInput input)
    {
        var username = input.Username.Trim().ToLowerInvariant();
        Require(Regex.IsMatch(username, "^[a-z0-9_]{3,32}$"), "Username must contain 3–32 letters, numbers or underscores.");
        Require(input.Name.Trim().Length is >= 1 and <= 80, "Name must contain 1–80 characters.");
        // Usernames remain stable so saved @mentions retain their meaning.
        var old = await db.Profiles.Find(x => x.Id == uid).FirstOrDefaultAsync();
        Require(old is null || old.Username == username, "Your username cannot be changed.");
        var profile = new Profile { Id = uid, Username = username, Name = input.Name.Trim() };
        try { await db.Profiles.ReplaceOneAsync(x => x.Id == uid, profile, new ReplaceOptions { IsUpsert = true }); }
        catch (MongoWriteException ex) when (ex.WriteError.Category == ServerErrorCategory.DuplicateKey)
        { throw new ChatException(409, "This username is already taken."); }
        return profile;
    }

    public async Task<Conversation> Member(string uid, string id) =>
        await db.Conversations.Find(x => x.Id == id && x.Members.Contains(uid)).FirstOrDefaultAsync()
        ?? throw new ChatException(404, "Conversation unavailable.");

    public async Task<List<Profile>> Members(string uid, string id)
    {
        var c = await Member(uid, id);
        return await db.Profiles.Find(x => c.Members.Contains(x.Id)).ToListAsync();
    }

    public async Task<Conversation> Create(string uid, ConversationInput input)
    {
        await Profile(uid);
        var members = input.Members.Append(uid).Distinct().Order().ToList();
        Require(members.Count is >= 2 and <= 50, "Choose between 2 and 50 members, including yourself.");
        Require(await db.Profiles.CountDocumentsAsync(x => members.Contains(x.Id)) == members.Count, "A selected contact no longer exists.");
        var group = input.Name is not null;
        Require(!group || members.Count >= 3, "Select at least 2 people for a new group.");
        Require(!group || input.Name!.Trim().Length is >= 1 and <= 80, "Group name must contain 1–80 characters.");
        var c = new Conversation { Type = group ? "Group" : "Direct", Name = input.Name?.Trim() ?? "", Owner = uid, Members = members };
        if (!group)
        {
            Require(members.Count == 2, "A direct chat has two members.");
            c.DirectKey = Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(string.Join('\0', members))));
            var existing = await db.Conversations.Find(x => x.DirectKey == c.DirectKey).FirstOrDefaultAsync();
            if (existing is not null) { await Reopen(uid, existing.Id); return existing; }
        }
        try { await db.Conversations.InsertOneAsync(c); }
        catch (MongoWriteException ex) when (ex.WriteError.Category == ServerErrorCategory.DuplicateKey && c.DirectKey is not null)
        { var existing = await db.Conversations.Find(x => x.DirectKey == c.DirectKey).FirstAsync(); await Reopen(uid, existing.Id); return existing; }
        await notifications.Event(c.Members, "ConversationsChanged", c.Id);
        return c;
    }

    private Task Reopen(string uid, string id) => db.Reads.UpdateOneAsync(x => x.Id == $"{uid}:{id}", Builders<ReadState>.Update.Set(x => x.Hidden, false));

    public async Task<object> Summary(string uid, Conversation c)
    {
        var state = await State(uid, c.Id);
        var last = await db.Messages.Find(x => x.ConversationId == c.Id && !x.Deleted && x.CreatedAt > state.ClearedAt).SortByDescending(x => x.Id).FirstOrDefaultAsync();
        var peers = await db.Profiles.Find(x => c.Members.Contains(x.Id)).ToListAsync();
        var reads = await db.Reads.Find(x => x.ConversationId == c.Id).ToListAsync();
        var unread = await db.Messages.CountDocumentsAsync(x => x.ConversationId == c.Id && !x.Deleted && x.SenderId != uid && x.CreatedAt > state.ReadAt && x.CreatedAt > state.ClearedAt);
        return new { c.Id, c.Type, Name = c.Type == "Group" ? c.Name : peers.FirstOrDefault(x => x.Id != uid)?.Name ?? "Unknown contact",
            c.Owner, c.Members, c.Revision, Profiles = peers, LastMessage = last, Unread = unread,
            Hidden = state.Hidden && (last is null || last.CreatedAt <= state.ClearedAt), Reads = reads };
    }
    public async Task<List<object>> List(string uid)
    {
        var conversations = await db.Conversations.Find(x => x.Members.Contains(uid)).SortByDescending(x => x.UpdatedAt).ToListAsync();
        var results = new List<object>();
        foreach (var c in conversations) results.Add(await Summary(uid, c));
        return results;
    }

    public async Task<Conversation> Edit(string uid, string id, GroupInput input)
    {
        var c = await Member(uid, id);
        Require(c.Type == "Group" && c.Owner == uid, "Only the group owner can edit members.", 403);
        var members = input.Members.Distinct().ToList();
        Require(members.Contains(uid) && members.Count is >= 2 and <= 50, "Keep the owner and 2–50 members.");
        Require(input.Name.Trim().Length is >= 1 and <= 80, "Group name must contain 1–80 characters.");
        Require(await db.Profiles.CountDocumentsAsync(x => members.Contains(x.Id)) == members.Count, "Unknown member.");
        var old = c.Members;
        c.Members = members; c.Name = input.Name.Trim(); c.Revision++;
        var result = await db.Conversations.ReplaceOneAsync(x => x.Id == id && x.Owner == uid && x.Revision == input.Revision, c);
        Require(result.ModifiedCount == 1, "Group changed. Reopen details and try again.", 409);
        if (old.Except(members).Any()) await EndCalls(id);
        await notifications.Event(old.Union(members), "ConversationsChanged", id);
        return c;
    }

    public async Task Leave(string uid, string id)
    {
        var c = await Member(uid, id);
        Require(c.Type == "Group", "Only groups can be left.");
        var old = c.Members.ToList(); var revision = c.Revision;
        c.Members.Remove(uid); c.Revision++;
        if (c.Owner == uid) c.Owner = c.Members.FirstOrDefault() ?? "";
        var result = await db.Conversations.ReplaceOneAsync(x => x.Id == id && x.Revision == revision, c);
        Require(result.ModifiedCount == 1, "Group changed. Try again.", 409);
        await EndCalls(id);
        await notifications.Event(old, "ConversationsChanged", id);
    }

    private async Task EndCalls(string id)
    {
        var active = await db.Calls.Find(x => x.ConversationId == id && x.EndedAt == null).ToListAsync();
        foreach (var call in active)
        {
            call.EndedAt = DateTime.UtcNow; call.Status = "Ended";
            await db.Calls.ReplaceOneAsync(x => x.Id == call.Id && x.EndedAt == null, call);
            await notifications.Event(call.Members, "CallChanged", call);
        }
    }

    public Task<ReadState> State(string uid, string id) => GetState(uid, id);
    private async Task<ReadState> GetState(string uid, string id) => await db.Reads.Find(x => x.UserId == uid && x.ConversationId == id).FirstOrDefaultAsync()
        ?? new ReadState { Id = $"{uid}:{id}", UserId = uid, ConversationId = id };

    public async Task Read(string uid, string id, string messageId)
    {
        var c = await Member(uid, id);
        var m = await db.Messages.Find(x => x.Id == messageId && x.ConversationId == id).FirstOrDefaultAsync();
        Require(m is not null, "Message unavailable.", 404);
        var update = Builders<ReadState>.Update.SetOnInsert(x => x.UserId, uid).SetOnInsert(x => x.ConversationId, id).Max(x => x.ReadAt, m!.CreatedAt);
        await db.Reads.UpdateOneAsync(x => x.Id == $"{uid}:{id}", update, new UpdateOptions { IsUpsert = true });
        await notifications.Event(c.Members, "MessagesRead", new { ConversationId = id, UserId = uid, ReadAt = m.CreatedAt });
    }

    public async Task Clear(string uid, string id, bool hide)
    {
        await Member(uid, id);
        var now = DateTime.UtcNow;
        await db.Reads.UpdateOneAsync(x => x.Id == $"{uid}:{id}", Builders<ReadState>.Update
            .SetOnInsert(x => x.UserId, uid).SetOnInsert(x => x.ConversationId, id).Set(x => x.ClearedAt, now).Max(x => x.ReadAt, now).Set(x => x.Hidden, hide), new UpdateOptions { IsUpsert = true });
        await notifications.Event([uid], "ConversationsChanged", id);
    }

    public async Task<Page<Message>> History(string uid, string id, string? before, string? query = null)
    {
        await Member(uid, id);
        return await Search(uid, query, id, before);
    }
    public async Task<Page<Message>> Search(string uid, string? query, string? id, string? before)
    {
        if (query is not null) Require(query.Trim().Length is >= 2 and <= 200, "Search needs 2–200 characters.");
        if (id is not null) await Member(uid, id);
        var conversations = await db.Conversations.Find(x => x.Members.Contains(uid)).ToListAsync();
        var ids = conversations.Where(x => id is null || x.Id == id).Select(x => x.Id).ToList();
        var states = await db.Reads.Find(x => x.UserId == uid).ToListAsync();
        var f = Builders<Message>.Filter;
        // Per-conversation clear boundaries also apply to full-history searches.
        var scopes = ids.Select(cid => f.Eq(x => x.ConversationId, cid) & f.Gt(x => x.CreatedAt, states.FirstOrDefault(s => s.ConversationId == cid)?.ClearedAt ?? DateTime.MinValue)).ToList();
        if (scopes.Count == 0) return new([], null);
        var filter = f.Or(scopes) & f.Eq(x => x.Deleted, false);
        if (before is not null)
        {
            Require(ObjectId.TryParse(before, out _), "Invalid history cursor.");
            var cursor = await db.Messages.Find(x => x.Id == before && ids.Contains(x.ConversationId)).FirstOrDefaultAsync();
            Require(cursor is not null, "Cursor belongs to an unavailable conversation.");
            filter &= f.Lt(x => x.Id, before);
        }
        if (query is not null)
        {
            var regex = new BsonRegularExpression(Regex.Escape(query.Trim()), "i");
            filter &= f.Regex(x => x.Text, regex) | f.Regex("Attachment.FileName", regex);
        }
        var items = await db.Messages.Find(filter).SortByDescending(x => x.Id).Limit(51).ToListAsync();
        var more = items.Count > 50; if (more) items.RemoveAt(50);
        return new(items, more ? items[^1].Id : null);
    }

    public static void ValidateSend(SendInput input)
    {
        Require(Guid.TryParse(input.ClientMessageId, out _), "A client UUID is required.");
        Require(!string.IsNullOrWhiteSpace(input.Text) && input.Text.Length <= 4000, "Message must contain 1–4,000 characters.");
    }
    public static bool SameRequest(Message saved, SendInput input, Attachment? attachment) =>
        !saved.Deleted && saved.Text == input.Text && saved.Reply?.Id == input.ReplyToMessageId &&
        saved.Attachment?.Hash == attachment?.Hash && saved.Attachment?.FileName == attachment?.FileName && saved.Attachment?.MimeType == attachment?.MimeType;

    public async Task<Message> Send(string uid, string id, SendInput input, Attachment? attachment = null)
    {
        ValidateSend(input);
        var c = await Member(uid, id); var sender = await Profile(uid);
        var existing = await db.Messages.Find(x => x.ConversationId == id && x.SenderId == uid && x.ClientMessageId == input.ClientMessageId).FirstOrDefaultAsync();
        if (existing is not null)
        {
            Require(SameRequest(existing, input, attachment), "This retry ID was already used for different content.", 409);
            return existing;
        }
        Quote? quote = null;
        if (input.ReplyToMessageId is not null)
        {
            var target = await db.Messages.Find(x => x.Id == input.ReplyToMessageId && x.ConversationId == id && !x.Deleted).FirstOrDefaultAsync();
            Require(target is not null, "Quoted message unavailable.", 404);
            var preview = target!.Attachment?.FileName ?? target.Text;
            quote = new(target.Id, target.SenderName, preview[..Math.Min(300, preview.Length)]);
        }
        var profiles = await db.Profiles.Find(x => c.Members.Contains(x.Id)).ToListAsync();
        var mentions = c.Type == "Group" && attachment is null ? profiles.Where(p => Regex.IsMatch(input.Text, $@"(?<![\w@])@{Regex.Escape(p.Username)}(?![\w])", RegexOptions.IgnoreCase)).Select(p => p.Id).ToList() : [];
        var m = new Message { ConversationId = id, SenderId = uid, SenderName = sender.Name, ClientMessageId = input.ClientMessageId,
            Text = input.Text, Reply = quote, Attachment = attachment, Mentions = mentions,
            Type = attachment is null ? "Text" : attachment.MimeType.StartsWith("image/") ? "Image" : attachment.MimeType.StartsWith("audio/") ? "Audio" : attachment.MimeType.StartsWith("video/") ? "Video" : "File" };
        try { await db.Messages.InsertOneAsync(m); }
        catch (MongoWriteException ex) when (ex.WriteError.Category == ServerErrorCategory.DuplicateKey)
        {
            existing = await db.Messages.Find(x => x.ConversationId == id && x.SenderId == uid && x.ClientMessageId == input.ClientMessageId).FirstAsync();
            Require(SameRequest(existing, input, attachment), "This retry ID was already used for different content.", 409);
            return existing;
        }
        // Save is authoritative. Notification failures cannot turn a successful save into a failed send.
        await db.Conversations.UpdateOneAsync(x => x.Id == id, Builders<Conversation>.Update.Max(x => x.UpdatedAt, m.CreatedAt));
        await notifications.Message(c, m);
        return m;
    }

    public async Task Delete(string uid, string id, string messageId)
    {
        var c = await Member(uid, id);
        var result = await db.Messages.UpdateOneAsync(x => x.Id == messageId && x.ConversationId == id && x.SenderId == uid,
            Builders<Message>.Update.Set(x => x.Deleted, true).Set(x => x.Text, ""));
        Require(result.MatchedCount == 1, "You can delete only your own messages.", 403);
        await notifications.Event(c.Members, "MessageDeleted", new { ConversationId = id, MessageId = messageId });
    }
}
