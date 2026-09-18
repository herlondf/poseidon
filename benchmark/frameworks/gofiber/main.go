package main

import (
	_ "embed"

	"github.com/gofiber/fiber/v2"
)

//go:embed large.json
var largeJSON []byte

func main() {
	app := fiber.New(fiber.Config{
		Prefork:               false,
		DisableStartupMessage: true,
		ServerHeader:          "",
	})

	app.Get("/plaintext", func(c *fiber.Ctx) error {
		c.Set(fiber.HeaderContentType, "text/plain")
		return c.SendString("Hello, World!")
	})

	app.Get("/json", func(c *fiber.Ctx) error {
		c.Set(fiber.HeaderContentType, "application/json")
		return c.SendString(`{"message":"Hello, World!"}`)
	})

	app.Get("/json-large", func(c *fiber.Ctx) error {
		c.Set(fiber.HeaderContentType, "application/json")
		return c.Send(largeJSON)
	})

	if err := app.Listen("0.0.0.0:8080"); err != nil {
		panic(err)
	}
}
