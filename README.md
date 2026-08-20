# Transkribering Cloud

En macOS-app för transkribering av ljud- och videofiler med OpenAI Whisper. Cloud-versionen är projektets huvudsakliga variant.

## Funktioner

- Import via filväljare eller dra och släpp
- Stöd för MP3, WAV, M4A, MP4 och FLAC
- Svenska, engelska och automatisk språkidentifiering
- Val av antal talare
- Lokal hantering av användare och transkript
- OpenAI API-nyckeln sparas i appens lokala inställningar och ingår inte i repot

## Kom igång

1. Öppna `Transkribering.xcodeproj` i Xcode.
2. Välj schemat **Transkribering Cloud**.
3. Bygg och kör appen.
4. Ange din OpenAI API-nyckel under **Inställningar**.

## Projektstruktur

- `TranskriberingCloud/` – Cloud-versionens vyer och Whisper-integration
- `Transkribering/` – delade modeller, vyer, resurser och lokal serverkod
- `TranskriberingPM/` – alternativ projektvariant

## Säkerhet

Lägg aldrig API-nycklar, ljudfiler, transkript eller signeringsfiler i Git. Projektets `.gitignore` exkluderar dessa typer av lokala filer.
