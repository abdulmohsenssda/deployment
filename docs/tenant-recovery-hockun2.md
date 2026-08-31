# Recover the `hockun2` dev tenant after the v0.0.1 drift

`hockun2.dev.ifritah.com` shipped with a mismatched backend + frontend
image pair. Both apps were tagged `:v0.0.1` on Docker Hub but the images
were built at different points in time:

| Image | Built from | Missing on the deployed image |
|-------|-----------|--------------------------------|
| `ifritah-api:v0.0.1`  | pre-`ifritah-go#50`  | `/api/v2/purchase_bill/duplicate-check` endpoint |
| `ifritah-web:v0.0.1`  | post-`go_ifritah#50` | (has the pre-check UI that calls the endpoint above) |

Playwright reproduction against `hockun2` confirmed:

- `POST /api/purchase-bills/duplicate-check → 404` (frontend proxy forwards
  the backend 404 verbatim, which triggers the yellow "تعذر التحقق من التكرار"
  banner in the Add Purchase Bill form).
- `POST /api/purchase-bills → 200` (the actual create endpoint is on both
  images, so bills can still be created if the user attaches a PDF and hits
  Save through the yellow banner).

## Fix (short version)

The scary banner and the "Save does nothing without PDF" silence are both
addressed by `go_ifritah#72`. The drift itself is prevented going forward by:

- `ifritah-go#70` — backend deploy workflow now publishes a `:dev` alias.
- `go_ifritah` deploy workflow already publishes a `:dev` alias.
- `scripts/update-tenant.sh` in this repo now preflights backend + frontend
  `org.opencontainers.image.version` labels and refuses to deploy a
  mismatched pair.

## Steps to recover the currently-broken `hockun2` tenant

1. Confirm the new `v0.0.2` images are on Docker Hub (both should carry the
   `org.opencontainers.image.version=v0.0.2` label from their build workflow):

   ```bash
   docker pull "${DOCKERHUB_USERNAME}/ifritah-api:v0.0.2"
   docker pull "${DOCKERHUB_USERNAME}/ifritah-web:v0.0.2"

   docker inspect --format='{{index .Config.Labels "org.opencontainers.image.version"}}' \
       "${DOCKERHUB_USERNAME}/ifritah-api:v0.0.2"
   docker inspect --format='{{index .Config.Labels "org.opencontainers.image.version"}}' \
       "${DOCKERHUB_USERNAME}/ifritah-web:v0.0.2"
   # Both must print: v0.0.2
   ```

2. Re-deploy the tenant. The drift preflight will refuse to deploy if the
   labels disagree:

   ```bash
   sudo ./scripts/update-tenant.sh hockun2 \
       --backend-image  "${DOCKERHUB_USERNAME}/ifritah-api:v0.0.2" \
       --frontend-image "${DOCKERHUB_USERNAME}/ifritah-web:v0.0.2" \
       --restart
   ```

   Expected on success:

   ```
   [+] Pulling image: .../ifritah-api:v0.0.2
   [+] Pulling image: .../ifritah-web:v0.0.2
   [+] Image versions match: v0.0.2 (backend + frontend)
   [+] Deploying backend:  .../ifritah-api:v0.0.2
   [+] Deploying frontend: .../ifritah-web:v0.0.2
   [+] Restarting tenant...
   ```

3. Smoke-test the tenant. Log in as `admin / Qwerty123` and confirm:

   ```
   POST https://hockun2.dev.ifritah.com/api/purchase-bills/duplicate-check
   with body {"supplier_id": <existing supplier id>, "supplier_sequence_number": 1}
   → 200 {"exists": false}
   ```

   And in the UI:

   - `/dashboard/products/add` shows a plain "اسم القطعة" text input, not the
     old "رقم القطعة OEM" search widget. Typing a free-text name and clicking
     Save creates the product.
   - `/dashboard/purchase-bills/add` no longer shows the yellow "تعذر التحقق من
     التكرار" banner. Clicking Save without a PDF now renders a visible red
     "يرجى رفع ملف فاتورة الشراء (PDF)" error and scrolls to the PDF slot;
     attaching a PDF and clicking Save creates the bill.

## Optional cleanup

The reproduction run left one test supplier (`مورد اختبار`, id 253) and two
purchase bills (`630264` and `7490047`) in the tenant DB. They are labelled
"مضاف يدوياً" and can stay for regression-testing the drift preflight later,
or be soft-deleted through the UI if the tenant is being handed to real
users.

## Preventing recurrence

Any future tenant deploy via `update-tenant.sh` will:

- Pull both images.
- Read `org.opencontainers.image.version` from each.
- Abort with a clear error message if the labels disagree, before touching
  any dokku config or container state.

The check can be bypassed with `--skip-drift-check` for targeted rollback
investigations, but doing so is loud (a warning is logged both to stdout and
stderr).
