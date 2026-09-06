# SACDPlayer

Plugin para Lyrion Music Server que expõe SACD ISO na biblioteca (áreas 2ch e mch como álbuns) e serve DSF extraído por `sacd_extract` a partir de um cache local com evicção LRU, mantendo a passagem nativa `dsf dsf * *` (DoP) do player.

Spec de desenho: `docs/superpowers/specs/2026-09-06-sacdplayer-design.md`.
