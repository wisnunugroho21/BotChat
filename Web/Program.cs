using System.Security.Claims;
using System.Threading.RateLimiting;
using FirebaseAdmin;
using Google.Apis.Auth.OAuth2;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.IdentityModel.Tokens;
using Standalone.Chat;

var builder = WebApplication.CreateBuilder(args);
builder.Configuration.AddJsonFile("appsettings.Local.json", optional: true).AddEnvironmentVariables();
var project = builder.Configuration["Firebase:ProjectId"];
if (string.IsNullOrWhiteSpace(project)) throw new InvalidOperationException("Set Firebase__ProjectId to your standalone Firebase project ID.");
builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme).AddJwtBearer(options => {
    options.Authority = $"https://securetoken.google.com/{project}";
    options.Audience = project;
    options.TokenValidationParameters = new TokenValidationParameters {
        ValidateIssuer = true, ValidIssuer = $"https://securetoken.google.com/{project}", ValidateAudience = true,
        ValidAudience = project, ValidateLifetime = true, NameClaimType = ClaimTypes.NameIdentifier,
        ClockSkew = TimeSpan.FromSeconds(30)
    };
    options.Events = new JwtBearerEvents { OnMessageReceived = context => {
        if (context.HttpContext.Request.Path.StartsWithSegments("/hubs/chat") && context.Request.Query.TryGetValue("access_token", out var token)) context.Token = token;
        return Task.CompletedTask;
    }};
});
builder.Services.AddAuthorization();
builder.Services.AddControllers();
builder.Services.AddSignalR(options => { options.MaximumReceiveMessageSize = 96 * 1024; options.EnableDetailedErrors = false; });
builder.Services.AddSingleton<ChatStore>();
builder.Services.AddSingleton<ChatService>();
builder.Services.AddSingleton<Notifications>();
builder.Services.AddSingleton<Presence>();
builder.Services.AddSingleton<CallService>();
builder.Services.AddRateLimiter(options => {
    options.RejectionStatusCode = 429;
    options.AddPolicy("api", context => RateLimitPartition.GetFixedWindowLimiter(
        context.User.FindFirstValue(ClaimTypes.NameIdentifier) ?? context.Connection.RemoteIpAddress?.ToString() ?? "unknown",
        _ => new FixedWindowRateLimiterOptions { PermitLimit = 240, Window = TimeSpan.FromMinutes(1), QueueLimit = 0 }));
});
if (builder.Configuration.GetValue<bool>("Firebase:EnablePush"))
    FirebaseApp.Create(new AppOptions { ProjectId = project, Credential = GoogleCredential.GetApplicationDefault() });
var app = builder.Build();
app.Use(async (context, next) => {
    try { await next(); }
    catch (ChatException ex) { context.Response.StatusCode = ex.Status; await context.Response.WriteAsJsonAsync(new { error = ex.Message }); }
    catch (Exception ex) {
        app.Logger.LogError(ex, "Request failed");
        context.Response.StatusCode = 500;
        await context.Response.WriteAsJsonAsync(new { error = "Something went wrong. Please retry." });
    }
});
app.UseAuthentication(); app.UseAuthorization(); app.UseRateLimiter();
app.MapControllers().RequireRateLimiting("api");
app.MapHub<ChatHub>("/hubs/chat").RequireAuthorization().RequireRateLimiting("api");
app.MapGet("/health", () => Results.Ok(new { status = "ok" }));
await app.Services.GetRequiredService<ChatStore>().Initialize();
app.Run();