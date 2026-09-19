using MongoDB.Bson;
using MongoDB.Driver;
using MongoDB.Driver.GridFS;

namespace Standalone.Chat;

public sealed class ChatStore
{
    public IMongoCollection<Profile> Profiles { get; }
    public IMongoCollection<Conversation> Conversations { get; }
    public IMongoCollection<Message> Messages { get; }
    public IMongoCollection<ReadState> Reads { get; }
    public IMongoCollection<Device> Devices { get; }
    public IMongoCollection<Call> Calls { get; }
    public GridFSBucket Files { get; }

    public ChatStore(IConfiguration config)
    {
        var client = new MongoClient(config["Mongo:ConnectionString"]);
        var db = client.GetDatabase(config["Mongo:Database"] ?? "standalone_chat");
        Profiles = db.GetCollection<Profile>("profiles");
        Conversations = db.GetCollection<Conversation>("conversations");
        Messages = db.GetCollection<Message>("messages");
        Reads = db.GetCollection<ReadState>("reads");
        Devices = db.GetCollection<Device>("devices");
        Calls = db.GetCollection<Call>("calls");
        Files = new GridFSBucket(db);
    }

    public async Task Initialize()
    {
        await Profiles.Indexes.CreateOneAsync(new CreateIndexModel<Profile>(Builders<Profile>.IndexKeys.Ascending(x => x.Username), new() { Unique = true }));
        await Conversations.Indexes.CreateManyAsync([
            new(Builders<Conversation>.IndexKeys.Ascending(x => x.Members)),
            new(Builders<Conversation>.IndexKeys.Ascending(x => x.DirectKey), new CreateIndexOptions<Conversation> {
                Unique = true, PartialFilterExpression = new BsonDocument("DirectKey", new BsonDocument("$type", "string")) })]);
        await Messages.Indexes.CreateManyAsync([
            new(Builders<Message>.IndexKeys.Ascending(x => x.ConversationId).Ascending(x => x.SenderId).Ascending(x => x.ClientMessageId), new() { Unique = true }),
            new(Builders<Message>.IndexKeys.Ascending(x => x.ConversationId).Descending(x => x.Id))]);
        await Reads.Indexes.CreateOneAsync(new CreateIndexModel<ReadState>(Builders<ReadState>.IndexKeys.Ascending(x => x.UserId).Ascending(x => x.ConversationId), new() { Unique = true }));
        await Devices.Indexes.CreateOneAsync(new CreateIndexModel<Device>(Builders<Device>.IndexKeys.Ascending(x => x.UserId)));
        await Calls.Indexes.CreateOneAsync(new CreateIndexModel<Call>(Builders<Call>.IndexKeys.Ascending(x => x.Members).Descending(x => x.CreatedAt)));
    }
}
