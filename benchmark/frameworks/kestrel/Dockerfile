# ─── Build stage ──────────────────────────────────────────────────────────────
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src

COPY kestrel.csproj ./
RUN dotnet restore kestrel.csproj

COPY Program.cs ./
RUN dotnet publish kestrel.csproj -c Release -o /app --no-restore

# ─── Runtime stage ────────────────────────────────────────────────────────────
FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS runtime
WORKDIR /app
COPY --from=build /app ./
COPY large.json ./

ENV ASPNETCORE_URLS=http://0.0.0.0:8080 \
    DOTNET_gcServer=1 \
    DOTNET_TieredPGO=1 \
    ASPNETCORE_ENVIRONMENT=Production

EXPOSE 8080
ENTRYPOINT ["dotnet", "kestrel.dll"]
