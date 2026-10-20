# Spotify + Spicetify Setup

One script that gets Spotify and Spicetify working on Windows, so you don't have to do it by hand.

## Run it

Open **PowerShell** (a normal window, not as administrator) and paste this:

```powershell
iwr -useb https://raw.githubusercontent.com/USER/REPO/main/Spotify-Spicetify-Setup.ps1](https://github.com/ElBulbol/spiectify_windows_fix/edit/main/Spotify-Spicetify-Setup.ps1 | iex
```

That's it. The script asks you to confirm before it touches anything, then does the rest.

> Prefer double-clicking? Download the project, **extract the zip**, and double-click `Run-Setup.bat`. Keep it in the same folder as the `.ps1` file.

## What it does

1. Downloads everything it needs first. If a download fails, nothing on your PC has changed.
2. Removes your current Spotify if you have one. No Spotify yet? It skips this and just installs fresh.
3. Installs Spotify **1.2.98.301**.
4. Blocks Spotify's auto-updates, so Spicetify keeps working.
5. Installs Spicetify (your existing themes and extensions are kept) and applies it.

The Spotify installer only runs if it's digitally signed by "Spotify AB".

## Good to know

- **Windows 10 or 11**, run as a normal user. The script refuses to run as admin on purpose, because Spotify shouldn't be installed that way.
- Want a preview first? Run it with `-DryRun` and it only shows what would happen:

  ```powershell
  & ([scriptblock]::Create((iwr -useb https://raw.githubusercontent.com/USER/REPO/main/Spotify-Spicetify-Setup.ps1))) -DryRun
  ```

- Other options: `-SpotifyVersion 1.2.98.301`, `-SpicetifyVersion latest`, `-Yes` (skip the confirmation question).
- A log is saved to `%TEMP%\Spotify-Spicetify-Setup.log` if something goes wrong.

## Undo the update block

If you want Spotify to be able to update again, run this in Command Prompt:

```
icacls "%localappdata%\Spotify\Update" /remove:d "%username%"
```

## Credits

Spicetify is made by the [Spicetify team](https://github.com/spicetify/cli). Older Spotify builds come from [LoaderSpot](https://loadspot.pages.dev/versions). This project isn't affiliated with Spotify.
