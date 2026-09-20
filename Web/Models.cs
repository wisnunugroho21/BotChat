using MongoDB.Bson;
using MongoDB.Bson.Serialization.Attributes;

namespace Standalone.Chat;

public static class Ids
{
    public static string New() => ObjectId.GenerateNewId().ToString();
    // MongoDB dates have millisecond precision. Return the same timestamp we persist.
    public static DateTime Now() => DateTimeOffset.FromUnixTimeMilliseconds(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()).UtcDateTime;
}
public sealed class Profile
{
    [BsonId] public string Id { get; set; } = "";
    public string Username { get; set; } = "";
    public string Name { get; set; } = "";
    public DateTime LastSeen { get; set; } = DateTime.UtcNow;
}
public sealed class Conversation
{
    [BsonId] public string Id { get; set; } = Ids.New();
    public string Type { get; set; } = "Direct";
    public string Name { get; set; } = "";
    public string Owner { get; set; } = "";
    public string? DirectKey { get; set; }
    public List<string> Members { get; set; } = [];
    public int Revision { get; set; }
    public DateTime UpdatedAt { get; set; } = DateTime.UtcNow;
}
public sealed class Message
{
    [BsonId] public string Id { get; set; } = Ids.New();
    public string ConversationId { get; set; } = "";
    public string SenderId { get; set; } = "";
    public string SenderName { get; set; } = "";
    public string ClientMessageId { get; set; } = "";
    public string Text { get; set; } = "";
    public string Type { get; set; } = "Text";
    public DateTime CreatedAt { get; set; } = Ids.Now();
    public Quote? Reply { get; set; }
    public Attachment? Attachment { get; set; }
    public List<string> Mentions { get; set; } = [];
    public bool Deleted { get; set; }
}
public sealed record Quote(string Id, string SenderName, string Preview, string Type = "Text");
public sealed record Attachment(string Id, string FileName, string MimeType, long Size, string Hash);
public sealed class ReadState
{
    [BsonId] public string Id { get; set; } = "";
    public string UserId { get; set; } = "";
    public string ConversationId { get; set; } = "";
    public DateTime ReadAt { get; set; }
    public DateTime ClearedAt { get; set; }
    public bool Hidden { get; set; }
    public bool Pinned { get; set; }
    public bool Muted { get; set; }
    public bool Archived { get; set; }
    public List<string> PinnedMessageIds { get; set; } = [];
}
public sealed class Device
{
    [BsonId] public string Id { get; set; } = "";
    public string UserId { get; set; } = "";
    public string Token { get; set; } = "";
    public DateTime UpdatedAt { get; set; } = DateTime.UtcNow;
}
public sealed class Call
{
    [BsonId] public string Id { get; set; } = Ids.New();
    public string ConversationId { get; set; } = "";
    public string CallerId { get; set; } = "";
    public string CallerName { get; set; } = "";
    public bool Video { get; set; }
    public List<string> Members { get; set; } = [];
    public List<string> Joined { get; set; } = [];
    public List<string> Declined { get; set; } = [];
    public string Status { get; set; } = "Ringing";
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    public DateTime? AnsweredAt { get; set; }
    public DateTime? EndedAt { get; set; }
}
public sealed record ProfileInput(string Username, string Name);
public sealed record ConversationInput(string? Name, List<string> Members);
public sealed record GroupInput(string Name, List<string> Members, int Revision);
public sealed record SendInput(string ClientMessageId, string Text, string? ReplyToMessageId = null);
public sealed record BroadcastInput(List<string> Recipients, string ClientMessageId, string Text);
public sealed record TokenInput(string Token);
public sealed record CallInput(bool Video);
public sealed record ConversationPreferences(bool? Pinned = null, bool? Muted = null, bool? Archived = null);
public sealed record PinInput(bool Pinned);
public sealed record Page<T>(List<T> Items, string? NextCursor);
public sealed class ChatException(int status, string message) : Exception(message)
{
    public int Status { get; } = status;
}
