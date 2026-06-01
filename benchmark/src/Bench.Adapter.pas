unit Bench.Adapter;

// Interface comum para os adaptadores de cada configuração de servidor.

interface

type
  IBenchAdapter = interface
    ['{A1B2C3D4-E5F6-4A1B-C2D3-E4F5A6B7C8D9}']
    // Executa uma request e retorna a latência em µs (microsegundos).
    // Levanta exceção em erro de transporte (não em 4xx/5xx).
    function Execute(
      const AURL:    string;
      const AMethod: string;
      const ABody:   string = ''
    ): Int64;
    // Limpa estado interno (ex: reset de conexão)
    procedure Reset;
    // Nome da configuração para display
    function Name: string;
    // Se False, testes são marcados como N/A (ex: SSL sem OpenSSL instalado)
    function IsAvailable: Boolean;
    // Cria nova instância independente do mesmo tipo (para testes concorrentes)
    function Clone: IBenchAdapter;
    // URL base do servidor-alvo (cada adaptador pode ter seu próprio servidor)
    function BaseURL: string;
    // Configura a latência injetada no FakeDAO do servidor embutido.
    // Deve ser chamado antes de cada cenário que usa rotas /users.
    // AMs = 0 desliga a latência simulada.
    procedure SetDAOLatencyMs(const AMs: Integer);
  end;

implementation

end.
