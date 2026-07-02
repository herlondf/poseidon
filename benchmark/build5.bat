@echo off
set PATH=C:\Program Files (x86)\Embarcadero\Studio\22.0\bin;%PATH%
mkdir "D:\IA\Projetos\Delphi\Poseidon\benchmark\dcu\Release" 2>/dev/null
mkdir "D:\IA\Projetos\Delphi\Poseidon\benchmark\bin" 2>/dev/null
dcc64.exe -Q "D:\IA\Projetos\Delphi\Poseidon\benchmark\Poseidon.Benchmark.dpr" -U"D:\IA\Projetos\Delphi\Poseidon\benchmark\src;D:\IA\Projetos\Delphi\Poseidon\src;C:\Program Files (x86)\Embarcadero\Studio\22.0\lib\Win64\release" -I"D:\IA\Projetos\Delphi\Poseidon\benchmark\src;D:\IA\Projetos\Delphi\Poseidon\src" -N"D:\IA\Projetos\Delphi\Poseidon\benchmark\dcu\Release" -E"D:\IA\Projetos\Delphi\Poseidon\benchmark\bin" -DRELEASE > "D:\IA\Projetos\Delphi\Poseidon\benchmark\bout.txt" 2>&1
echo EXIT_CODE=%ERRORLEVEL% >> "D:\IA\Projetos\Delphi\Poseidon\benchmark\bout.txt"
