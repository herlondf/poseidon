Rails.application.routes.draw do
  get "plaintext", to: "bench#plaintext"
  get "json", to: "bench#json_small"
  get "json-large", to: "bench#json_large"
end
