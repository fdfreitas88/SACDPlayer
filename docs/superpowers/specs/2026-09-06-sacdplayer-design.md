# SACDPlayer: SACD ISO na biblioteca do LMS com cache local

Data: 2026-09-06. Estado: aprovado em brainstorming, aguardando plano de implementação.

## 1. Problema e objetivo

Nada na cadeia LMS (musicplayer) -> Apple Squeezer -> Chord Mojo lê SACD ISO. O DSDPlayer instalado (fork terual 1.12) só aceita DSF/DFF/WavPack-DSD; o engine Audiophile_Squeezelite registra `dsf,dff`; o Daphile também não lê ISO (FAQ Q9). O usuário quer o comportamento do Pine Player (abrir ISO e tocar) com uma diferença: extração persistida num cache no disco local do musicplayer, para não reler nem redecodificar o ISO a cada play.

Resultado esperado: ISOs num SMB aparecem na biblioteca como álbuns normais, tocam por DoP bit-perfect como um DSF comum, e o disco interno do servidor guarda os DSF extraídos com limite de tamanho.

## 2. Decisões tomadas

| Tema | Decisão |
|---|---|
| Onde ficam os ISO | NAS via SMB (`//192.168.0.30/Disk8TB` montado em `/Volumes/Disk8TB-1`) |
| Onde fica o cache | Disco interno do musicplayer, padrão `~/Library/Caches/Squeezebox/SACDPlayer/` |
| Quando extrair | Lazy (no primeiro play) e manual (botão "preparar álbum"); nunca no scan |
| Política de cache | Cap em GB configurável, evicção LRU por álbum inteiro |
| Áreas | 2ch e mch viram álbuns separados, sufixos "(2ch)" e "(mch)"; mch toca só L/R |
| Faixas DST no primeiro play | Extrair a faixa inteira antes de tocar, com aviso "preparando"; velocidade medida em spike |
| UI | Verbos JSON-RPC + página de settings no LMS; Echo Classic integra depois (detect and degrade) |
| Abordagem | Plugin LMS: tipo playlist estilo CUE para o scan + handler de protocolo `sacd://` subclasse de `Slim::Player::Protocols::File` |

## 3. Arquitetura

Repositório `~/Desktop/Claude/LMS/SACDPlayer`, plugin `Plugins::SACDPlayer`, instalado em `~/Library/Caches/Squeezebox/InstalledPlugins/Plugins/SACDPlayer` no musicplayer.

### 3.1 `Bin/darwin/sacd_extract`
Binário x86_64 compilado no MacBook (arm64, Xcode) a partir do fork github.com/Sound-Linux-More/sacd-extract com `-arch x86_64`, sem dependências dinâmicas fora do sistema. Resolvido por `Slim::Utils::Misc::findbin` (o PluginManager adiciona `Bin/darwin` ao caminho de busca). Não vai ao git; o processo de release copia o binário.

### 3.2 `Scanner.pm`
- `custom-types.conf`: `sacd iso audio/x-sacd-iso playlist` e `sacd sacd: ? audio` (forma de esquema, como `cdplay:` no CDplayer).
- No `init` do plugin: `$Slim::Formats::tagClasses{sacd} = 'Plugins::SACDPlayer::Scanner'`.
- Subclasse de `Slim::Formats::Playlists::Base`; `read()` segue `Slim::Formats::Playlists::CUE` (`CUE.pm:640-720`): o ISO é gravado com `CONTENT_TYPE => 'cur'`, `AUDIO => 0`; cada trilha vira faixa virtual (`VIRTUAL => 1`) com URL `sacd://<caminho-do-iso>?area=2ch|mch&track=N`, título, artista, duração, número e álbum `<título> (2ch)` ou `<título> (mch)`.
- Chave do ISO: hash curto de caminho + tamanho + mtime. Índice `index/<chave>.json` com o parse do `sacd_extract -P`; reaproveitado nos rescans, invalidado quando tamanho ou mtime mudam.
- `sacd_extract -P` com timeout de 60 s; falha loga aviso e pula o ISO.

### 3.3 `ProtocolHandler.pm`
- Subclasse de `Slim::Player::Protocols::File`, registrada com `Slim::Player::ProtocolHandlers->registerHandler('sacd', ...)`.
- `contentType` -> `dsf`; `isRemote` -> 0; `canSeek` -> 1 quando a faixa está em cache.
- `getNextTrack`: consulta o Cache. Em cache: atualiza último acesso e libera. Ausente: enfileira a faixa (prioridade alta) e o resto do álbum (normal), mostra "Preparando faixa N de M" e aguarda por timer do LMS (`Slim::Utils::Timers`), sem bloquear. Timeout padrão 10 min, depois erro e próxima faixa. Pular de faixa durante a espera reordena a fila.
- `pathFromFileURL`: devolve `<cache>/<chave>/<area>/<NN>.dsf`. Como o player recebe um DSF real em disco, aplica a regra nativa `dsf dsf * *` de `convert.conf` (capacidades `IFD`, comando `-`); nenhum `custom-convert.conf` é escrito.
- Após a extração, a faixa virtual recebe `audio_size`, `audio_offset`, `samplerate`, `channels` e `block_alignment` lidos do DSF, para seek funcionar em `File::open`.

### 3.4 `Cache.pm`
- Layout `<cache>/<chave>/<area>/<NN>.dsf`, temporários em `<cache>/tmp/`, índice `index/<chave>.json` com tamanho, último acesso e estado por faixa (`pendente`, `extraindo`, `pronta`, `falhou` + mensagem).
- Extração: `sacd_extract -2|-m -s -c -t N -i <iso> -y <tmp>` via `Proc::Background`, um processo por vez, verificação a cada 1 s por timer. Rename atômico ao terminar; o arquivo só existe no destino quando completo.
- Fila com prioridades: faixa pedida pelo play > resto do álbum > pedidos manuais. Persistida no índice; ao subir o LMS, `extraindo` volta a `pendente` e temporários órfãos são apagados.
- LRU: após cada extração, se o total ultrapassa o cap, apaga álbuns inteiros por último acesso, exceto o álbum em reprodução e os que têm faixas na fila. `evict` manual usa a mesma rotina. Rescan nunca apaga cache.
- Disco: se o espaço livre cair abaixo de 5 GB, a fila pausa e settings avisa.

### 3.5 `Commands.pm` e `Settings.pm`
- `addDispatch` idempotente (padrão de `AppleSqueezerIntel/Commands.pm`): `['sacdplayer','prepare','_target']`, `['sacdplayer','status','_target']`, `['sacdplayer','evict','_target']`, `['sacdplayer','cachestats']`. `_target` aceita `album_id` ou URL `sacd://`. `status` devolve por faixa `state`, `bytes` e mensagem de erro; `cachestats` devolve uso, cap, fila e binário presente.
- `Settings.pm`: subclasse de `Slim::Web::Settings`; campos caminho do cache, cap em GB, timeout; tabela de ISOs com estado e botões preparar/apagar.
- Prefs em `preferences('plugin.sacdplayer')`.

## 4. Erros e limites
- Binário ausente ou ISO inacessível: erro de faixa legível, LMS avança, uma linha de log por ocorrência.
- `sacd_extract` com saída diferente de zero: temporário apagado, faixa `falhou` com a mensagem; sem retry automático; `prepare` limpa e reenfileira.
- Um único worker; mutex no índice; nada bloqueia o loop do LMS. Rescan e extração podem correr juntos.
- Álbum "(mch)" toca só L/R (comportamento do engine, `dsd.c:534-540`); rótulo deixa explícito.
- Compatibilidade: LMS 9.x; servidor macOS 12.7 Intel (i5-2435M, 2 núcleos); não interfere com DSDPlayer nem SqueezeDSP.

## 5. Fora do escopo
Downmix multicanal; extração em streaming; saída DSDIFF; DVD-Audio; capas a partir do ISO; integração no Echo Classic (sub-projeto seguinte: sonda `sacdplayer cachestats` e mostra selo em três estados + botão preparar, seguindo a política detect-and-degrade).

## 6. Spike de medição (antes de qualquer Perl)
No musicplayer, com um ISO de teste no SMB:
1. Tempo e formato exato de `sacd_extract -P` pelo SMB (fixa o parser).
2. Velocidade de extração de uma faixa DSD não comprimida e de uma DST, em múltiplos do tempo real (decide o texto de aviso, o timeout e se vale um segundo worker).
3. O binário x86_64 compilado no MacBook roda no macOS 12 sem dependências externas.
Os números voltam para este spec.

## 7. Testes
- Perl `prove`, padrão do AppleSqueezerIntel.
- Parser do `-P` contra fixtures capturadas no spike (disco só mch, título vazio, vários discos).
- Cache: LRU, cap, rename atômico, recuperação após restart, com um `sacd_extract` falso em shell que gera DSF sintético.
- Handler: URL -> caminho; estados em cache / pendente / falhou.
- Ponta a ponta no musicplayer: rescan com um ISO, dois álbuns no Echo Classic, play mostra "preparando", engine loga `DSD64 stream, format: DOP, rate: 176400Hz`, LED branco no Mojo, resto do álbum chega ao cache em segundo plano, `evict` remove sem afetar a biblioteca.

## 8. Referências de código (LMS 9.1.1 no musicplayer)
Core em `/Applications/Lyrion Music Server.app/Contents/MacOS/Lyrion Music Server.app/Contents/Resources/server`:
`Slim/Music/Info.pm:94-146` (custom-types.conf), `Slim/Formats.pm:43-113` (tagClasses), `Slim/Formats/Playlists/CUE.pm:531,640-720,820-845`, `Slim/Utils/Scanner/Local.pm:913-950,1243-1259`, `Slim/Player/Protocols/File.pm:27-63,245,299,310`, `Slim/Player/Protocols/LocalFile.pm`, `Slim/Utils/Misc.pm:107`, `Slim/Utils/PluginManager.pm:340-363`, `convert.conf:389`. Plugins: `CDplayer/CDPLAY.pm`, `CDplayer/custom-types.conf`, `AppleSqueezerIntel/Commands.pm:12-42`, `DSDPlayer/PlayerSettings.pm`.
