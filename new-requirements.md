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

# New Requirements — Content plan (FR-08)

Decisions taken while building the Контент-план module across
`frilance-frontend` and `frilance-backend`. FR-08 itself is in the SRS; what
follows is what the SRS left open, and one thing it contradicted.

## 15. The calendar is the screen; the mockup's list view is not built

`index.html` offers two views of a client's month — a list sorted by
status/date, and a table with every day of the month — behind a Список /
Таблиця toggle. Built functionality is the table only: FR-08 names the
module "календар публікацій" and its acceptance criterion is that a created
post "відображається в календарі відповідного місяця", which the list view
cannot show (a day with nothing planned doesn't appear in it, so there is
nowhere to click to plan one). The mobile layout is the same calendar with
the empty days dropped — 31 rows of "нічого" is most of a phone screen — so
the list-shaped reading of the month exists there.

If the list view comes back as a real requirement, it is a second rendering
of data the page already has, not new endpoints.

## 16. A post has no separate assignee; the client's assignee is the answer

FR-08's main flow lists "відповідальний" among a post's fields. It isn't
stored: `GET /api/v1/team` is owner-only (#11), so a PM or SMM has no way to
list the tenant's members and therefore no way to fill such a picker. A post
belongs to a client and a client already carries `assigneeId`, so
responsibility is answerable today without a second field that only the
owner could set.

Building it properly means a members-lookup endpoint scoped to "names of
people in my tenant" — deliberately narrower than the roster #11 closed —
and that is the piece to add first if per-post assignment is wanted.

## 17. Four statuses, not three, and only a published post carries a rating

The SRS sketches the lifecycle as "заплановано → в роботі →
знято/опубліковано" and marks it an example ("наприклад"). The implemented
cycle is `DRAFT → REVIEW → READY → PUBLISHED`: the review step the agency
actually has, and already what the dashboard's weekly strip and its seeded
data speak. Clicking the status chip advances one step and wraps.

FR-08's 3-point rating applies only to a `PUBLISHED` post — rating one that
hasn't run yet is a guess, and the FR feeds posts rated ≥ 2 to the AI report
generator (FR-15) as evidence of what worked. Moving a post back out of
PUBLISHED clears its rating for the same reason. Clicking the current rating
clears it, which is the mockup's separate "скинути" link without the second
control.

## 18. The content plan carries its own client picker

A member may hold Content access and no Clients access, so the plan cannot
source its client list from `GET /api/v1/clients` — that endpoint would
correctly 403 them out of a picker they need in order to plan anything.
`GET /api/v1/content-plan` returns the clients visible to the caller as part
of the section's own payload.

## 19. FR-08's SMM scoping applies to the Overview strip too

"SMM бачить у контент-плані лише публікації прикріплених до нього клієнтів"
was enforced nowhere: the dashboard's content-plan week was gated on the
Content grant (#13) but then showed every client's posts to whoever had it.
The week is five days of the same plan, so it now filters by the same
visibility rule. That rule moved into `ClientVisibility` (clients module),
which the clients module, the content plan and the dashboard all call —
one definition, so the screens cannot disagree about who sees whom.

## 20. The content plan has three views of one month; "Список" is #15's table

`content-plan/content-plan.html` draws the module as a week of day columns —
seven cards, each holding the publications scheduled on that day — behind a
Тиждень / Місяць / Список toggle, over a ruler showing where the visible
week sits in the month. That is what the screen renders now: the week grid
is the default, the month view is the same day cards laid out as a calendar
grid, and **Список is the day-by-day table #15 already described** (every
day of the month as a row, empty days included). #15's other reading of
"список" — posts sorted by status rather than by date — is still not built
and is still not needed for FR-08's acceptance criterion.

Two consequences worth knowing before extending this:

- A week straddles two months five times a year, and
  `GET /api/v1/content-plan` serves one month per call. The page asks for
  every month the visible range touches (one or two) and merges the answers
  rather than the endpoint growing a date range — the month stays the cache
  key, so switching between the week and month views re-uses what's already
  loaded. If ranges ever get wider than a week, that's the point to give the
  endpoint `from`/`to` instead.
- The mockup's post card shows a publication time (10:00), the toolbar a
  "Спеціаліст" filter, and the detail panel a cover image, caption, platform,
  responsible person and comments. None of those are stored (see #16 for the
  responsible person), so none are rendered. The card shows the post's topic
  where the mockup shows its time; the panel is still the create/edit form,
  now with the mockup's status stepper in place of a status dropdown. Adding
  any of the rest means new columns on `post`, not just markup.

### 20a. The status scale is four distinguishable hues, not the mockup's

The mockup colours READY green and PUBLISHED green-brand. In this app's light
palette `--success` and `--brand-500` are **the same hex** (`#3E6549`), so the
last two steps of the lifecycle were one colour on half the app. READY is
therefore `--info` (blue-grey) and PUBLISHED is `--success`, giving
grey → amber → blue-grey → green across DRAFT/REVIEW/READY/PUBLISHED.

This scale is duplicated in three files and they must not drift:
`ContentPlanPage.module.css` (the legend), `ContentPlanBoard.module.css` (the
card's left border and its status chip's dot) and
`ContentPlanCalendar.module.css` (the table's chips). The legend renders above
the board views only — the table names every status in its own column, so a
colour key there was redundant *and* was the thing that made the earlier
mismatch visible.

## 21. A post records its author — the member who created it

FR-08's post gains `author_id` / `author_name` (V12). The author is taken from
the authenticated principal at creation and is **never** rewritten: editing
somebody else's post leaves their name on it, and a member who later changes
their display name keeps the name they published under. `author_name` is
denormalized like `client_name` so the plan renders without joining the auth
module, but unlike `client_name` it is deliberately not refreshed on write.

Why the creator rather than a picker: a picker is the "відповідальний" field
#16 already ruled out, and for the same reason — `GET /api/v1/team` is
owner-only, so a PM or SMM has no way to list the tenant's members and fill
one. "Who wrote this" needs nobody to be asked. If per-post *assignment* is
wanted later, #16 still stands: build the narrow members-lookup endpoint
first, and add it as a second field beside the author rather than overloading
this one.

Both columns are nullable and posts created before V12 have neither.
Backfilling them to the tenant owner would invent an attribution that never
happened, so the UI renders the absence instead: the board card omits its
author line entirely, the table shows an em dash, and the drawer says
"Невідомий".

The frontend has one display name to work with, not two — `user_account` has
a single `full_name`, so "ім'я та прізвище" is whatever the member's profile
holds ("Діана М.", "Оксана"). Splitting it into given/family names is a
change to the auth module, not the content plan.

## 22. A client is staffed by a set of members, not one

FR-05's `client.assignee_id` held a single specialist. V13 replaces it with a
`client_assignee` join table: a client carries any number of members, and each
existing assignment was carried over before the column was dropped.

**This is an access-control table, not a label.** `ClientVisibility` reads it
to answer FR-05's "SMM бачить лише прикріплених до нього клієнтів", and FR-08
restates the same rule for the content plan — so adding somebody to a client
shows them that client, its posts and its detail drawer, and removing them
takes all of it away again. The picker says so in as many words rather than
leaving it to be discovered.

Decisions taken with the user, and what they rule out:

- **Replace, don't keep a lead.** There is no "primary" member; the
  Спеціаліст column is a stack of avatars. If an account lead is ever needed
  it is a new flag on the join row, not a resurrection of `assignee_id`.
- **Anyone with CLIENTS = FULL may staff a client**, not just the owner. That
  required the narrow members lookup #16 asked for:
  `GET /api/v1/clients/assignable-members` returns id, name, initials and role
  for the caller's tenant — deliberately narrower than the owner-only roster
  #11 closed, with no email, no access matrix and no invite state. It is
  guarded on Clients *edit*, because the names of members already staffed on a
  client come embedded in the client itself.
- **Every role is assignable**, owner and PM included: on a small team the
  owner runs accounts personally. Members whose invite is still pending are
  listed too — they simply see the client once they claim it.

Two consequences worth knowing:

- A member with CLIENTS FULL can unstaff **themselves** from a client they can
  see, and then no longer see it. Nothing stops this; the owner can put them
  back. Blocking it would need a rule about who may remove whom, which nobody
  has asked for.
- Writes replace the whole set. The API has no add-one/remove-one operation,
  so a client sent without `assigneeIds` is a client with nobody on it.

### 22a. Restaffing is its own endpoint

`PUT /api/v1/clients/{id}/assignees` changes who is on a client without
touching anything else, mirroring the existing `/status` sub-resource. It is
not a convenience: `ClientDetailDto` — everything the client screen holds —
carries no `tariffPlan` and only a formatted `cooperationDurationLabel`
rather than the start date, so a caller rebuilding a full
`PUT /clients/{id}` from what it can see would silently null both. Narrow
updates cannot lose a field they never mention.

The staffing section lives in the client detail drawer's Огляд tab, read-only
under a Clients READ grant. Both it and the create drawer render the same
`AssigneePicker` molecule, so the two cannot drift about what ticking a member
means.

### 22b. Row scoping applies to every panel that draws from clients

The dashboard's "Потребують уваги" panel read `findByOwnerIdAndStatusOrderByNameAsc`
directly — tenant-filtered but not row-scoped — so any member with a Clients
grant saw the names and latest activity of every ATTENTION client in the
agency, including ones `GET /clients/{id}` would 404 for them. It now goes
through `ClientVisibility` like the content-plan strip beside it (#19).

The unscoped finder has been removed from `ClientRepository` rather than left
for the next caller to reach for, and the interface's Javadoc now says that
*which* clients a member may see is `ClientVisibility`'s answer, not a
repository's. Adding a `findByOwnerId…` finder satisfies the tenant rule and
still leaks across members — the two checks are independent.

## 23. A completed client takes no new posts

Nothing may be *planned* for a client whose cooperation is over: `POST
/api/v1/content-plan/posts` refuses a client in that state with a 400, and the
create form closes the option off before the round trip.

**«Завершено» is `ClientStatus.ARCHIVED`.** There is no separate COMPLETED
status and this requirement does not add one — ARCHIVED is already the end of
the cooperation, and it is what the client card's timeline itself labels
«Завершено» (`CooperationTimeline`'s `completedOverride`). A second status
meaning almost the same thing would need a rule for how the two differ, which
nobody has one for.

(An earlier draft of this entry called that timeline label the only place the
word appears in the product. It was not: `CooperationDurationFormatter` returns
"завершено" as a cooperation-duration label, and this requirement's own copy
added two more uses in `uk.ts`. The mapping to ARCHIVED stands; the claim of
uniqueness was wrong.)

Decisions taken with the user, and what they rule out:

- **It applies to everybody, the tenant owner included.** The refusal is a
  property of the client, not of who is asking, so it is not a permission and
  it is not in the access matrix — `AccessService` still decides whether the
  member may write in Content at all, and this check runs after it. There is
  no override; if an archived client genuinely needs new content, the answer
  is to take it out of the archive.
- **Creation only.** Posts already on a completed client stay editable,
  publishable, rateable and deletable. The plan that ran while the cooperation
  was live is a record of what happened, and freezing it half-finished would
  lose the report the client was archived with.
- Moving an *existing* post onto a completed client is therefore still
  allowed. `updatePost` re-resolves the client for visibility (#19) but does
  not re-check this rule — deliberately, as the narrower "create only" scope
  the user chose. Widening it is a one-line change in `ContentPlanService` if
  the looser edge turns out to matter.

The picker keeps listing completed clients: it doubles as the plan's filter,
and their months stay worth reading. `ContentPlanClientDto` therefore carries
`archived`, which is the only way the create form can know — the content plan
serves its own client lookup (#19) precisely because a member with Content but
not Clients access cannot call `/clients` to find out.

In the drawer that means the completed client is **not in the picker at all**
while creating. A disabled option was the first cut and it was the wrong one:
an entry you can see but never choose reads as a bug in the list, and the list
is a `<select>` a member scrolls, not a place to publish a client's status.
Editing still lists it — a post already on such a client has to be able to show
whose it is — and there it is named "{name} (завершено)", which is the one
context where the label explains rather than teases.

The substitution that follows is announced, never silent: when the page's
filter is on a completed client and the user asks to plan on it, the form falls
to the first client it *can* plan for and says under the picker that «{name}»
is finished. A post landing on the wrong client because the drawer quietly
moved on is the failure this is guarding against. If every client the member
has is completed there is nothing to fall to, so the picker reads "Спершу додай
клієнта" and submit is disabled. Nearly the shape of having no clients at all —
with one addition: the notice still names the completed client the page was
filtered to, so the empty picker is explained rather than bare.

As always the UI is a courtesy; the backend refuses the write regardless.

## 24. A post carries a note — rich text, written with the post

Every publication in the content plan has one free-form note: the brief, the
references, what was agreed with the client. It is written in the create form
and edited afterwards in the same form, by anybody who may edit content — there
is no separate permission and no separate endpoint. `POST` and `PUT
/content-plan/posts` carry it like any other field, which also means the PUT's
full-replacement semantics apply: an update without a note is a post without
one.

Decisions taken with the user, and what they rule out:

- **Rich text, not markdown and not plain text.** Bold, italic, underline and
  bulleted/numbered lists, with emoji as ordinary characters. The editor is
  TipTap (`@tiptap/react` + `starter-kit`), the first real UI dependency in the
  frontend and a deliberate exception to this repo's build-it-ourselves habit —
  a markdown-lite field with a hand-rolled renderer was the alternative and was
  turned down. **It costs about 440 KB raw / 140 KB gzip**, roughly doubling the
  bundle (332 KB → 773 KB) and tripping Vite's chunk-size warning. If that
  becomes a problem the fix is to lazy-load the editor on first open rather than
  to swap the library.
- **One note per post, not a comment thread.** No author, no timestamp, no
  replies. The mockup's comments panel (#20) is still not built; this is the
  field it would have sat next to, not a smaller version of it.
- **The drawer is the only place it appears.** No marker on the board card, no
  column in the list view — so a note is visible only to somebody who opens the
  post. That is the chosen trade-off; if notes turn out to be missed, a card
  marker is the smallest thing that would fix it.

### 24a. HTML in a column is only safe because of the sanitizer

The note is the **only column in this schema that stores markup**, and it comes
from a browser, so it is untrusted input. `PostNoteSanitizer` runs an OWASP
allowlist over every write: the elements the editor can produce, and **no
attributes at all**. No attribute means no `href` to make `javascript:`, no
`onerror`, no `style`, no `src` — the usual vectors have nothing to ride in on.
Widening that list is a security decision, not a formatting one.

The editor's extension list and the sanitizer's allowlist are two halves of one
decision and must move together. Enable something in TipTap that the sanitizer
drops and the server silently strips it back out, which reads to the user as
data loss; allow something in the sanitizer the editor cannot produce and it is
attack surface nobody is using. Strikethrough was dropped from both for exactly
this reason; `b` and `i` stay in the allowlist only as the spellings the editor
normalizes on paste.

Two behaviours worth knowing before anybody reads this column outside an HTML
context:

- **Escaping inflates what is stored, so the length limit is measured on the
  sanitized output.** The renderer escapes `"`, `'`, `=`, `` ` `` and every
  character outside the BMP into numeric references: 🔥 is stored as
  `&#x1f525;`, and a note of ordinary Ukrainian prose with quotes runs about
  1.6× its typed length (emoji, up to 4.5×). `PostNoteSanitizer.MAX_LENGTH`
  therefore caps the *result*, not the request — the DTO's `@Size` is only an
  outer bound on how much markup the server will parse.

  Measuring the request was a real bug and is worth not reintroducing: a note
  could pass validation on create and then be too long to send back, and since
  the post form resubmits the stored note whenever any other field is edited,
  the post became permanently unsaveable. The property that makes the current
  cap correct is that sanitizing is idempotent, so anything accepted once is
  accepted again — `PostNoteSanitizerTest.whateverItAcceptsItAcceptsAgain`
  pins it.

  Emoji surviving as references is otherwise harmless: every HTML consumer,
  the editor included, sees the same character. But a grep over the column, or
  a plain-text rendering of a note, will not see an emoji. Cyrillic is
  untouched.
- **An empty editor is no note.** `<p></p>`, whitespace and `&nbsp;`-only markup
  all normalize to `NULL` on write, so "has a note" stays a null check rather
  than a string comparison every caller has to get right.

  That rule exists twice — `PostNoteSanitizer.hasVisibleText` and the frontend's
  `isBlankNote` — because the editor decides client-side whether to send a note
  at all and the server decides whether to keep what arrives. They must agree,
  and their test cases are deliberate mirrors of each other. TipTap's own
  `editor.isEmpty` is what this replaced: it disagreed in both directions,
  calling a lone Shift+Enter non-empty and an outline of empty bullets empty.

### 24b. Errors a user reads are chosen by code, not by prose

`ApiError` gained a `code` — a stable machine-readable tag — and the frontend
picks its own wording from it (`i18n/apiErrorMessage.ts`). Two codes exist so
far: `CLIENT_COMPLETED` (#23's refusal) and `NOTE_TOO_LONG`.

This closes a hole the note work opened. Every backend message is English, and
`PostDrawer` rendered `err.message` straight into the form — so a Ukrainian user
met "Cannot plan a post for a completed client", which the frontend's own
never-hardcode-a-string rule exists to prevent. Worse, a Bean Validation
failure's `message` is the literal "Validation failed": the useful, already
localized text sits in `details`, which the API client was discarding. The
resolver now prefers a known code, then `details`, and only falls back to
`message` — the reverse of what it did.

Codes are a contract with the client, so renaming one is a breaking change, and
an error worth showing a user is worth tagging. The remaining untagged errors
("Post not found", "Only a published post can be rated") still surface in
English; tag them as each one turns out to be user-facing.


## 25. A client's drawer carries that client's content plan, month by month

Opening a client and switching to its «Контент-план» tab now shows that
client's plan instead of the mockup's placeholder copy: one whole calendar
month of it, with ‹ › to walk to any other month. Each row is a post — date,
weekday (or "сьогодні"), title, type, the member who wrote it, and status.

The member is the post's `authorName` (#21), not the client's staffing: the
staffing is the same on every row of a client-scoped plan and already sits in
the Огляд tab, so repeating it 20 times would say nothing. The author varies
per post and was the one thing this surface knew and did not show. It is null
on posts that predate the column, and renders as nothing there — the em dash
belongs to the list view, where a table cell has to hold its column.

It is **labelled** («Автор: {name}»), like the board card and unlike the first
attempt here. The drawer's own header renders the client's staffing as a
`·`-joined list of member names a few rows above, so a bare name in a
`·`-joined meta line reads as one more assignee.

**Read-only, and a list rather than the module's grid.** It is not the module
embedded in a drawer. The plan's writes all need the board around a post to
make sense, and editing here would stack a `PostDrawer` on top of the client
drawer; everything that changes a post stays in the Контент-план module. The
month is drawn as a list of what is planned, not the module's day-by-day grid,
because the drawer is 440px on a desktop and a bottom sheet on a phone — a
month is mostly empty days, and 31 rows of "нічого" is several screens here.
Days with nothing on them get no row.

**One month per view is what the endpoint serves.** `GET /content-plan` takes
a single `month`, so the tab is a single `useQuery` — no range, nothing to
merge, and therefore no partial-failure state to report. It deliberately does
*not* retain the previous month while the next loads, though the single query
would allow it: the month label is local state that flips on the click, so
retained rows appear under the wrong heading, and retrying a failed month
brings the old one back looking like a success. The module never had that class
of bug because `buildMonthDays` drops posts dated outside the month it is
given; a flat list does not. Paging shows the loading line instead, with the
navigator still on screen.

**The month navigator is outside every state it wraps.** Loading, empty and
failed all render *inside* the navigator, never instead of it — the same rule
the module's toolbar follows. Navigation is how someone leaves a month that has
nothing in it or would not load; a state that replaces its own navigation traps
whoever reached it.

**Access follows the data, not the screen.** The drawer belongs to Clients but
the posts are the CONTENT section's, so the tab is gated on `canView("CONTENT")`
and shows a "no access" state — and issues no request — without it. Same shape
as #13's Overview panels. The backend re-checks either way: `ContentPlanService`
scopes every read to the clients the member may see.

**Where it lives.** `ClientDetailDrawer` gained a `contentTab` slot rather than
the ability to fetch a content plan; `ClientsPage` fills it with
`ClientContentPlanTab`. Passing an element means the tab only mounts — and only
fetches — once the user selects it, so opening a client, which always lands on
Огляд, costs the content plan nothing. The tab reads the same
`contentPlanQueryKey` the module does (the key moved to `api/contentPlan.ts`
for that), so `usePostMutations`' blanket invalidation of the `contentPlan`
prefix keeps both surfaces honest. It rarely saves a request, though: the
module keys its months on whichever client its filter names, and that is `null`
("усі") unless somebody picked one, so the cache hit only lands when the module
is already filtered to this same client. `monthTitle` moved to
`utils/calendarDays.ts` in the same change, now that two screens name a month.

**Laziness needed a bug fixed to be true.** The drawer used to reset its
selected tab in an effect on open, and effects run after the commit — so
reopening a client whose detail was still cached rendered one frame on the tab
last left open. That cost nothing while every tab was static copy, but with a
fetching tab behind one of them it meant a `GET /content-plan` for a tab the
member never selected. The selected tab is now state inside
`ClientDetailContent`, keyed on the client: closing the drawer drops `detail`,
unmounts it, and resets the tab with no post-commit correction at all.

**Superseded within this entry:** the tab was first built as a five-post
"upcoming" list over a two-month look-ahead. Whole months with navigation
replace it — the look-ahead answered "is anything coming up" but could not
answer "what did we publish last month", and its window ("the rest of this
month plus all of next") was a span no honest copy could name.
