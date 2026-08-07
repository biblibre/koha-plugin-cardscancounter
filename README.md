# Card Scan Counter Koha plugin

Anonymous footfall counter: an unauthenticated OPAC kiosk page lets patrons
scan their card (barcode reader or RFID reader in keyboard-emulation mode),
and the plugin records `branchcode`, `categorycode`, `sort1`, `sort2` and a
timestamp for each visit - without keeping personal data longer than needed.

## How it works

- **Kiosk page**: `GET /api/v1/contrib/cardscancounter/scan` serves a
  self-contained page with a visible cardnumber field, styled with this
  OPAC's own theme (links the OPAC's `opac.css`, uses its form/button
  classes). It has no OPAC header or navigation, so a patron can't wander
  off from the kiosk. No OPAC login is required.
- **Deduplication**: a repeated scan of the same card within a configurable
  window (default 5 minutes, capped under 24h) is not counted again. The
  cardnumber is never stored in clear text - only a salted HMAC-SHA256 hash
  is kept, and only long enough to detect same-day duplicates.
- **Nightly purge** (`cronjob_nightly`, run by
  `misc/cronjobs/plugins_nightly.pl`, already scheduled in Koha's standard
  crontab):
  - `purge_daily_card_hashes` clears the card hash (sets it to `NULL`) of
    every row from the previous day, since it no longer serves any purpose
    once the day is over;
  - `purge_expired_scans` deletes rows older than the configured retention
    window (default 90 days) entirely.
- **Statistics**: this plugin does not provide any report. Use Koha's
  Reports module (SQL reports) against the plugin's table, e.g.:

    ```sql
    SELECT branchcode, categorycode, DATE(scanned_at) AS visit_date, COUNT(*) AS visits
    FROM koha_plugin_com_biblibre_cardscancounter_scans
    WHERE scanned_at BETWEEN <<Start date|date>> AND <<End date|date>>
    GROUP BY branchcode, categorycode, DATE(scanned_at)
    ORDER BY visit_date;
    ```

## Requirements

- Koha 25.11+ (uses the `cronjob_nightly` plugin hook and anonymous
  `/api/v1/contrib/...` plugin routes)

## Setup

1. Once the plugin is installed, open its configuration page from the Koha
   plugins list (Actions > Configure) to set the deduplication window
   (minutes) and the retention window (days).
2. Point the kiosk workstation's browser at
   `/api/v1/contrib/cardscancounter/scan`.

## Data protection notes

- The cardnumber is required to detect duplicate scans, but it is never
  stored: only a salted hash is kept, cleared every night regardless of the
  configured retention window.
- The salt ("pepper") is generated per installation at install time
  (`Koha::AuthUtils::generate_salt`) and stored internally by the plugin; it
  is never exposed through the API.
- The API always replies the same way (a plain `204 No Content`) whether the
  scan was recorded, ignored as a duplicate, or ignored because the card is
  unknown to Koha, so the endpoint cannot be used to probe which cardnumbers
  exist.

## Sponsor

Mines Paris Tech
