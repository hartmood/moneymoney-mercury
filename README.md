# Mercury MoneyMoney Extension

Unofficial extension for integrating [Mercury.com](https://mercury.com/) via their REST API into the macOS app [MoneyMoney](https://moneymoney-app.com/).

**Current version:** see `SCRIPT_VERSION` in [`MercuryWebBanking.lua`](MercuryWebBanking.lua) (header comment).

## Features

- Checking and savings via `GET /api/v1/account/{id}`
- Treasury **balance** via `GET /api/v1/treasury`
- Treasury **transactions** via `GET /api/v1/treasury/{id}/transactions` (cursor pagination; not `/account/.../transactions`)
- Credit cards via `GET /api/v1/credit` (balances negated for MoneyMoney)
- Robust **name-based** detection (MoneyMoney renames accounts, e.g. a prefix before „Treasury“)

## Installation

1. Quit MoneyMoney (Cmd+Q).
2. Open the MoneyMoney **Extensions** folder (e.g. **Hilfe → Datenbank im Finder anzeigen → Extensions**).
3. Copy [`MercuryWebBanking.lua`](MercuryWebBanking.lua) into that folder.
4. In MoneyMoney, add an account and search for **Mercury API**.
5. Put your **Mercury API token** in the password field.

## Notes

- Mercury docs: [Treasury transactions](https://docs.mercury.com/reference/gettreasurytransactions)
- This repository contains **only** the plugin file; a larger private workspace may track the same file elsewhere.
