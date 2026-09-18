use actix_web::{get, App, HttpResponse, HttpServer};

static LARGE_JSON: &[u8] = include_bytes!("../large.json");

#[get("/plaintext")]
async fn plaintext() -> HttpResponse {
    HttpResponse::Ok()
        .content_type("text/plain")
        .body("Hello, World!")
}

#[get("/json")]
async fn json() -> HttpResponse {
    HttpResponse::Ok()
        .content_type("application/json")
        .body(r#"{"message":"Hello, World!"}"#)
}

#[get("/json-large")]
async fn json_large() -> HttpResponse {
    HttpResponse::Ok()
        .content_type("application/json")
        .body(LARGE_JSON)
}

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    HttpServer::new(|| {
        App::new()
            .service(plaintext)
            .service(json)
            .service(json_large)
    })
    .bind(("0.0.0.0", 8080))?
    .run()
    .await
}
