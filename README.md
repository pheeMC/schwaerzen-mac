# Schwärzen

Mac-App zum Schwärzen von Datenraum-Unterlagen (M&A, Insolvenz). Alles läuft lokal auf dem Mac.

**Ablauf:** Mandat anlegen → Ordner hineinziehen → Office wandelt in PDF um → Erkennung (Personalliste, feste Regeln, lokales KI-Modell) → Prüfung pro Person/Begriff → Freigeben (Seiten werden neu aufgebaut, Dateinamen anonymisiert, Protokoll lokal).

## Download

Die fertige App liegt unter **Releases** → `Schwaerzen.zip` (wird bei jedem Push automatisch gebaut).

1. ZIP laden und entpacken, `Schwaerzen.app` nach „Programme“ ziehen.
2. Erster Start: Rechtsklick → **Öffnen** (oder Systemeinstellungen → Datenschutz & Sicherheit → „Trotzdem öffnen“).
3. Beim ersten Umwandeln fragt macOS, ob Schwärzen Word/Excel/PowerPoint steuern darf → erlauben.

Voraussetzungen: macOS 26 oder neuer, Apple Silicon. Microsoft Office für Word/Excel/PowerPoint-Dateien.
Das KI-Modell wird aus HideMyData übernommen, falls vorhanden, sonst einmalig geladen (ca. 1,5 GB).

## Was erkannt wird

| Quelle | Beispiele |
|---|---|
| Listen | Personalliste (→ MA-Personalnummer), Kreditoren, Debitoren, Immer-Liste |
| Feste Regeln | IBAN (mit Prüfziffer), Steuer-ID, SV-Nummer, Ausweis, Konfession/Kirchensteuer, Steuerklasse, Kinderfreibeträge, Krankenkasse, Geburtsdatum, E-Mail, Telefon |
| KI (lokal) | Namen, Anschriften, Kontaktdaten (OpenAI Privacy Filter via OpenMedKit/MLX) |

Krankmeldungen, BEM-, Arzt- und Schwerbehindertenunterlagen, Bewerbungen und Beurteilungen werden automatisch ausgeschlossen.

## Bauen

```
brew install xcodegen
xcodegen generate
open Schwaerzen.xcodeproj
```

## Lizenz

GPL-3.0. Teile übernommen aus [HideMyData](https://github.com/mkbula/HideMyData) (GPL-3.0), nutzt [OpenMedKit](https://github.com/maziyarpanahi/openmed) und [CoreXLSX](https://github.com/CoreOffice/CoreXLSX).
