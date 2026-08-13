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

# New Requirements — Team Module (FR-02/FR-03, `develop-team` branch)

Requirements gathered while building the Team screen (`team/team.html` mockup)
across `frilance-frontend` and `frilance-backend`.

## 6. Individual accounts for every team role, ahead of the SRS baseline

The SRS's FR-02 only gives real login credentials to Owner and PM; SMM and
Targetolog share one team password with no individual authentication. The
SRS itself (closing risk note, end of FR-02) names this as a known
simplification and recommends moving to personal accounts "in a future
version."

This requirement pulls that future version forward now: the Owner can invite
**any** role (PM, SMM, Targetolog) as a named individual with their own
account, superseding the shared-team-password login for invited members.
The shared-password path in the SRS is left as-is for anyone not yet
migrated to an individual account; it is not being removed by this work.

## 7. Invite / activation flow (no email/SMTP infrastructure)

Since the backend has no outbound-email capability:

- Owner submits **name + email + role** only (no password) to invite a
  member. The account is created in an `INVITED` state and cannot log in
  yet — a random, unguessable placeholder credential is stored so no
  plaintext password ever exists for it.
- The invited person self-activates via a public "claim invite" screen:
  they enter the email the invite was sent to, a one-time invite token
  (see requirement #9), and choose their own password. The account flips
  to `ACTIVE` and they're logged in immediately. No email is actually sent
  by the system yet — the owner relays the activation link (email + token
  baked into the URL) to the invitee out-of-band (Slack, in person, etc.).

## 8. Access stays role-based, not a per-member override matrix
### (superseded by #10)

The `team.html` mockup shows a per-member, per-section (Клієнти /
Контент-план / Таргет / Фінанси / Аналітика) editable access matrix. Built
functionality reuses the existing `RoleAccessPolicy` (role → fixed access
flags) instead: the matrix in the UI is a **read-only computed view** of the
selected role's access, not a stored per-member override. A true per-member
override system is explicitly out of scope for this pass — flagged for a
future requirement if the product actually needs finer-grained control than
role-based access.

## 9. Invite claiming requires a one-time token, not just the email (security fix)

An independent review (bug hunt on this branch, see task history) found that
the original design — claim an invite with only the invited email and a new
password — was exploitable: `GET /api/v1/team` shows every pending
invitee's email to *any* authenticated tenant member, so any team member
(even the lowest-privileged SMM) could see a pending PM invite's email and
claim it first, walking away with a PM-role account. There was also no way
for the owner to undo it — re-inviting the same email just 409'd.

Fixed by:

- `TeamService#invite` now also generates a random one-time token
  (`UUID.randomUUID()`), stores only its bcrypt hash
  (`user_account.invite_token_hash`, migration V8), and returns the raw
  token to the owner **exactly once**, in the invite response
  (`InviteTeamMemberResponse`) — never again, not even from `GET
  /api/v1/team`.
- `POST /api/v1/auth/claim-invite` requires the token to match; every
  failure path (unknown email, already-claimed, wrong token) returns the
  identical generic message so none of them can be distinguished from the
  outside — closes both the hijack and an email/claim-status enumeration
  oracle.
- `AuthService#login` no longer has a special-cased message for an
  INVITED account (it naturally fails the ordinary password check against
  the random placeholder hash) — same fix, applied to the login endpoint.
- New owner-only `DELETE /api/v1/team/{id}` lets the owner revoke a
  still-pending invite (bad email typo, or a hijack that already
  happened) and re-invite with a fresh token — the recovery path that was
  missing.
- Frontend: `InviteTeamMemberDrawer` shows the one-time activation link
  (email + token as query params) with a copy button after a successful
  invite; `ClaimInvitePage` accepts `email`/`token` query params to
  prefill; `TeamTable` gets an owner-only "cancel invite" action on
  `INVITED` rows, using the existing `ConfirmationDialog`. The invite
  button/FAB/drawer are now hidden entirely for non-owners (previously
  visible-but-always-403 for anyone who found `/team`).

## 10. Per-member section access, set by the owner (supersedes #8)

Requirement #8 deferred the `team.html` access matrix to "a future
requirement if the product actually needs finer-grained control than
role-based access." It does: the owner grants access themselves, per
member, when creating the teammate.

Three levels per section, which is the whole model:

- **Немає / None** — the member cannot see the tab or reach it at all; its
  read endpoints reject the request and the nav item is not rendered.
- **Перегляд / Read** — the tab opens, but nothing in it can be created or
  changed.
- **Повний / Full** — read plus create/update/delete.

The five sections are the ones in the mockup's matrix: Клієнти,
Контент-план, Таргет, Фінанси, Аналітика. Overview is the landing screen
every member gets, and the Team tab stays owner-only rather than becoming a
grantable section — an owner able to grant team management away could grant
away their own tenant.

### The grants replace role-based section access, they don't narrow it

For an invited PM/SMM/Targetolog the stored grants are the entire answer:
the role becomes a label, not an access level, and the owner can grant a
section the role never had (e.g. Фінанси to an SMM). `RoleAccessPolicy`
keeps only what isn't the owner's to hand out:

- `ownsTenant` — an OWNER/FREELANCER is the tenant, so their access is full
  by construction and is never stored as grants.
- `canManageTeam` — inviting members and editing their access.
- `allClients` — FR-05's rule that an SMM sees only the clients assigned to
  them. Orthogonal to None/Read/Full: the grant decides whether the Clients
  tab opens, this decides how much of it they see once inside.

### Editable after creation

Owner-only `PATCH /api/v1/team/{id}/access` replaces a member's whole
matrix (a partial one is a 400, never a silent NONE). Grants are read from
the database on each access check rather than carried as a JWT claim, so a
change applies to the member's *existing* session immediately instead of
whenever their 24h token happens to expire. `GET /api/v1/auth/me` lets a
signed-in client re-read its own grants so the UI catches up too.

### Enforcement, and what the UI does

Enforced server-side in `AccessService` (`requireView`/`requireEdit`), wired
into every Clients endpoint and the dashboard's finance summary — the two
modules that exist today; each new module wires its own section the same
way. The frontend hides what a member can't use (nav items for NONE
sections, create/update controls under READ, a route guard for typed URLs),
but that is cosmetic: the backend rejects the call regardless.

Migration `V9__add_member_access.sql` backfills every existing account from
its role so nobody loses access at upgrade time; the same values are
`RoleAccessPolicy.DEFAULT_ACCESS`, which is what the invite form pre-fills
when the owner picks a role.

# Corrections from the full-codebase logic review

A read-only review of both repos (requested after the Team module was built)
looked for code that contradicts its own stated rules. What it found changed
three product decisions, recorded here because they supersede wording above.

## 11. The team roster is owner-only (narrows #9's premise)

Requirement #9 justified the one-time invite token by saying `GET
/api/v1/team` shows every pending invitee's email "to *any* authenticated
tenant member" — accurate, but it was describing a hole rather than a
design. The endpoint had no authorization check at all, so any member could
read every colleague's email, who was still unclaimed, and each person's
complete access matrix.

The roster is now owner-only, like every other endpoint in the module. This
does **not** remove the invite token: an email address is guessable and gets
relayed out of band, so it still proves nothing about who is claiming. The
token stays as the thing that does.

Consequences elsewhere: the Team nav item and `/team` route are owner-gated
on the frontend (they were visible to everyone, and the page rendered the
full roster for anyone who opened it), and the Overview screen's team
workload panel is owner-only too — it is the same roster with load
percentages attached.

## 12. Revoking is limited to pending invites (narrows #9)

`DELETE /api/v1/team/{id}` deleted any account in the tenant regardless of
status, though #9 scopes it to undoing a still-pending invite and the UI
only ever offered it on `INVITED` rows. It now rejects anything else with a
400.

Removing an **active** teammate is a separate feature, not yet built: it has
to decide what happens to the clients assigned to them, which hard-deleting
the account silently did not.

## 13. Every Overview panel is gated on the section it draws from

Requirement #10 says a section granted NONE "cannot be seen or reached at
all". Overview is the screen every member lands on, and only its Finance
panel honoured that — the revenue hero (monthly total, month-over-month
delta, and a point per payment received), the ledger's amounts and
directions, the attention list's client names, and the content-plan week
were all served to any member regardless of grants.

Each panel is now gated on its own source section. A panel the member cannot
see comes back absent — `null` for revenue, empty for the lists — rather than
403ing the whole screen, since the rest of Overview is legitimately theirs.
Absent deliberately is not zeroed: a `₴0` revenue hero reads as a fact about
the business rather than as "not yours to see".

## 14. A client's assignee must belong to the tenant

`assigneeId` arrived from the client and was stored without checking, while
the lookup that resolves it to a name has no tenant filter — so an id from
another agency came back as that person's real name inside this tenant's
client list. It also created a row no scoped member could open again, since
their visibility rule is "assigned to me". Now validated on create and
update.
