# Certificados de Teste para o Benchmark SSL

Gere o certificado auto-assinado com OpenSSL antes de rodar o benchmark com SSL:

```
openssl req -x509 -newkey rsa:2048 -keyout certs\bench-server.key ^
  -out certs\bench-server.crt -days 3650 -nodes -subj "/CN=127.0.0.1"
```

Sem o certificado, o adaptador SSL aparece como **N/A** no relatório.
