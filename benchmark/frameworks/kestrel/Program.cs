using System.Text;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Server.Kestrel.Core;

var builder = WebApplication.CreateSlimBuilder(args);

builder.WebHost.ConfigureKestrel(options =>
{
    options.AddServerHeader = false;
    options.ListenAnyIP(8080, listen => listen.Protocols = HttpProtocols.Http1);
});

var app = builder.Build();

// Pre-computed UTF-8 payloads: exact bytes, zero per-request allocation/serialization.
byte[] plaintext = Encoding.UTF8.GetBytes("Hello, World!");
byte[] json = Encoding.UTF8.GetBytes("{\"message\":\"Hello, World!\"}");
// Read the large JSON once at startup; serve the exact bytes unchanged (no re-serialization).
byte[] jsonLarge = File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "large.json"));

app.MapGet("/plaintext", (HttpContext ctx) =>
{
    var res = ctx.Response;
    res.StatusCode = 200;
    res.ContentType = "text/plain";
    res.ContentLength = plaintext.Length;
    return res.Body.WriteAsync(plaintext, 0, plaintext.Length);
});

app.MapGet("/json", (HttpContext ctx) =>
{
    var res = ctx.Response;
    res.StatusCode = 200;
    res.ContentType = "application/json";
    res.ContentLength = json.Length;
    return res.Body.WriteAsync(json, 0, json.Length);
});

app.MapGet("/json-large", (HttpContext ctx) =>
{
    var res = ctx.Response;
    res.StatusCode = 200;
    res.ContentType = "application/json";
    res.ContentLength = jsonLarge.Length;
    return res.Body.WriteAsync(jsonLarge, 0, jsonLarge.Length);
});

app.Run();
