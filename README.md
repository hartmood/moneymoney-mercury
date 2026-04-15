# Mercury MoneyMoney Extension

Unafficial extension for integrating [Mercury.com](https://mercury.com/) web banking into the macOS App [MoneyMoney](https://moneymoney-app.com/).

## Features
- Fully supports Checking & Savings accounts
- Fully supports Treasury accounts (via `/treasury` endpoint)
- Fully supports Credit Cards (via `/credit` endpoint, balances are correctly negated)
- Name-based auto-detection to prevent mapping errors

## Installation
1. Go to your MoneyMoney Extensions folder (Help -> Show Database in Finder -> `Extensions`).
2. Drop `MercuryWebBanking.lua` into this folder.
3. Add a new account in MoneyMoney, search for "Mercury".
4. Enter your Mercury API Token as the password.
