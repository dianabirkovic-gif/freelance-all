# New Requirements — Clients Module (FR-05)

Requirements gathered during the Clients module ("Новий клієнт") work across
`frilance-frontend` and `frilance-backend`.

## 1. Add new client

Implement the "add new client" flow on the Clients page: a form to create a
client, wired to the backend's client-creation endpoint.

## 2. Mobile entry point for adding a client

- On mobile viewport, the `.newClientBtn` button must **not** be displayed.
- On mobile, adding a new client is instead triggered through the FAB
  (floating action button) in the mobile tab bar.

## 3. Контактна особа (Contact person) fields

- **Ім'я** (Name) — required.
- **Мобільний телефон** (Mobile phone) — required.
- **Email** — required.

## 4. Archive client action

When the user presses **Архівувати** on the client detail card, the
client's status changes to `ARCHIVED`.

## 5. Custom confirmation popup

Create a reusable organism representing a confirmation popup/dialog, used
in place of the browser's default `window.confirm()` wherever the app needs
the user to confirm a consequential action (starting with the archive-client
action from requirement 4).
