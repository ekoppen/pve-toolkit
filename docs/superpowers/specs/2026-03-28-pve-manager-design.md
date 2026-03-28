# PVE Server Beheer Menu — Design Spec

**Datum:** 2026-03-28
**Status:** Goedgekeurd

## Doel

Een interactief beheermenu (`pve-manager.sh`) voor de Proxmox-host zelf, startend met systeemupdates en opslag-overzicht. Uitbreidbaar met toekomstige opties.

## Scope

### Menu

```
╔══════════════════════════════════════╗
║       PVE Server Beheer             ║
╚══════════════════════════════════════╝

1) Systeemupdates
2) Opslag-overzicht
0) Afsluiten
```

Het menu draait in een loop — na elke actie keert de gebruiker terug naar het hoofdmenu.

### 1) Systeemupdates

- `apt update` uitvoeren
- `apt list --upgradable` tonen
- Als er updates zijn: bevestiging vragen ("Wil je deze updates installeren? [j/N]")
- Bij "j": `apt dist-upgrade -y` uitvoeren
- Na afloop: check `/var/run/reboot-required` en meld indien nodig

### 2) Opslag-overzicht

- `pvesm status` ophalen en parsen
- Tabelweergave: naam, type, totaal, gebruikt, vrij, percentage
- Kleurcodering: groen (<70%), geel (70-90%), rood (>90%)

## Technisch

- **Bestand:** `scripts/pve-manager.sh`
- **Stijl:** Zelfde kleuren en helper-functies als bestaande scripts
- **Root-check:** Verplicht bij opstarten
- **Subcommando's:** `pve-manager.sh update` en `pve-manager.sh storage` voor directe aanroep
- **install.sh:** Wordt bijgewerkt — script wordt mee gekopieerd, en usage-sectie toont `pve-manager.sh`

## Uitbreidbaarheid

Nieuwe menu-items toevoegen = nieuwe functie + extra regel in het menu. Geen structuurwijzigingen nodig.
