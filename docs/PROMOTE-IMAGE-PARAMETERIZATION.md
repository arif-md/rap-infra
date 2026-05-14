# promote-image.yaml Parameterization Guide

> **⚠️ SUPERSEDED — November 2025**
>
> The old monolithic `promote-frontend.yaml` / `promote-backend.yaml` / `promote-processes.yaml`
> workflows (~1340 lines each with hardcoded frontend references) have been **replaced** by:
>
> - `_promote-image.yaml` — single reusable workflow (~500 lines) that handles all services
> - `promote-frontend.yaml`, `promote-backend.yaml`, `promote-processes.yaml` — thin wrappers
>   (~25 lines each) that call `_promote-image.yaml` via `uses:`
>
> **This document is kept for historical reference only.** For current guidance on adding a
> new service promotion workflow, see [WORKFLOWS.md](./WORKFLOWS.md#step-2-create-promotion-workflow).

---

## Historical Context

This document tracked the partial parameterization of `promote-image.yaml` to support multiple
services. The work revealed that copy-and-modify at ~1340 lines was unmaintainable — any bug
fix required updating three identical files simultaneously.

The final architecture instead extracts all promotion logic into one reusable workflow
(`_promote-image.yaml`) and replaces per-service files with 25-line wrappers that only
specify the service identity (`service-key`, `service-suffix`, `service-label`).


**Before:**
```yaml
if echo "$REPO_PART" | grep -qE 'frontend-(dev|test|train|prod)'; then
  BASE_ENV=$(... 's@.*frontend-((dev|test|train|prod)).*@\1@p')
```

**After:**
```yaml
PATTERN="${SERVICE_KEY}-(dev|test|train|prod)"
if echo "$REPO_PART" | grep -qE "$PATTERN"; then
  BASE_ENV=$(... "s@.*${SERVICE_KEY}-((dev|test|train|prod)).*@\1@p")
```
- Now works with `raptor/frontend-dev`, `raptor/backend-test`, etc.

## ⚠️ What Still Needs Parameterization

The file has **~1400 lines** with hardcoded references in 3 promotion jobs (test, train, prod). Each job has similar patterns.

### Critical Hardcoded References (Need Manual Update When Duplicating)

#### A. Environment Variable Names (12 occurrences)
**Lines:** 104, 222, 582, 688, 1016, 1122

**Pattern:**
```yaml
FRONTEND_REPO_READ_TOKEN: ${{ secrets.FRONTEND_REPO_READ_TOKEN }}
```

**Should be:**
```yaml
# At job level, dynamically set based on SERVICE_KEY
SERVICE_REPO_READ_TOKEN: ${{ secrets[format('{0}_REPO_READ_TOKEN', env.SERVICE_KEY_UPPER)] }}
```

**Or simpler for duplication:**
```yaml
# For backend workflow
BACKEND_REPO_READ_TOKEN: ${{ secrets.BACKEND_REPO_READ_TOKEN }}
```

#### B. Container App Names (15+ occurrences)
**Lines:** 182, 457, 506, 539, 648, 883, 932, 965, 1082, etc.

**Pattern:**
```yaml
APP_NAME=$(echo "${ENV}-rap-fe" | tr '[:upper:]' '[:lower:]')
```

**Should be:**
```yaml
APP_NAME=$(echo "${ENV}-rap-${{ env.SERVICE_SUFFIX }}" | tr '[:upper:]' '[:lower:]')
```

**Impact:** CRITICAL - affects Container App lookups and updates

#### C. ACR Repository Names (6 occurrences)
**Lines:** 426, 458, 853, 884, etc.

**Pattern:**
```yaml
TARGET_REPO="raptor/frontend-${{ steps.prep.outputs.env }}"
IMG="${{ steps.prep.outputs.acr }}.azurecr.io/raptor/frontend-..."
```

**Should be:**
```yaml
TARGET_REPO="raptor/${{ env.SERVICE_KEY }}-${{ steps.prep.outputs.env }}"
IMG="${{ steps.prep.outputs.acr }}.azurecr.io/raptor/${{ env.SERVICE_KEY }}-..."
```

**Impact:** CRITICAL - affects image import and deployment

#### D. azd Environment Variable Names (6 occurrences)
**Lines:** 449, 875, etc.

**Pattern:**
```yaml
azd env set SERVICE_FRONTEND_IMAGE_NAME "..."
```

**Should be:**
```bash
SERVICE_KEY_UPPER=$(echo "${{ env.SERVICE_KEY }}" | tr '[:lower:]' '[:upper:]')
IMAGE_VAR="SERVICE_${SERVICE_KEY_UPPER}_IMAGE_NAME"
azd env set "$IMAGE_VAR" "..."
```

**Impact:** CRITICAL - affects azd environment configuration

#### E. FQDN Output Names (12 occurrences)
**Lines:** 500, 512, 516, 926, 938, 942, etc.

**Pattern:**
```yaml
RAW=$(azd env get-value frontendFqdn 2>/dev/null || true)
azd env set frontendFqdn "$FQDN"
echo "frontendFqdn=$FQDN" >> $GITHUB_OUTPUT
echo "- Frontend: https://$FQDN"
```

**Should be (for consistency):**
```yaml
# Note: These should stay service-specific for workflow outputs
# When duplicating for backend, change to:
RAW=$(azd env get-value backendFqdn 2>/dev/null || true)
azd env set backendFqdn "$FQDN"
echo "backendFqdn=$FQDN" >> $GITHUB_OUTPUT
echo "- Backend: https://$FQDN"
```

**Impact:** MEDIUM - affects workflow outputs (intentionally service-specific)

#### F. Email Subject Lines (3 occurrences)
**Lines:** 305, 725, etc.

**Pattern:**
```yaml
SUBJECT="$SUBJECT_PREFIX Promote frontend to ${TARGET_ENV}"
```

**Should be:**
```yaml
SUBJECT="$SUBJECT_PREFIX Promote ${{ env.SERVICE_KEY }} to ${TARGET_ENV}"
```

**Impact:** LOW - cosmetic, but good for clarity

## 🎯 Recommended Approach

Given the file's size (1400+ lines) and repetition, we recommend **one of two strategies**:

### Strategy 1: Parameterize Remaining References (Complete Solution)
**Pros:**
- Single workflow handles all services
- Maximum code reuse
- Easier to maintain long-term

**Cons:**
- Complex changes across 1400 lines
- Higher risk of introducing bugs
- Difficult to review/test

**Complexity:** HIGH (requires ~40-50 replacements across file)

### Strategy 2: Create Service-Specific Workflows (Pragmatic Solution) ✅ RECOMMENDED
**Pros:**
- Simple and safe - just copy & change 2 variables + service-specific names
- Easy to review and test
- Each service workflow is independent
- Matches pattern used for `infra-azd.yaml`

**Cons:**
- Some code duplication (but manageable with shared scripts)
- Need to maintain multiple workflow files

**Complexity:** LOW (copy file, change ~10 values)

## 📋 How to Create Backend Promotion Workflow (Strategy 2)

### Step 1: Copy the File
```bash
cp .github/workflows/promote-image.yaml .github/workflows/promote-image-backend.yaml
```

### Step 2: Update Service Configuration (Lines 3-6)
```yaml
env:
  SERVICE_KEY: backend    # ← Change from 'frontend'
  SERVICE_SUFFIX: be      # ← Change from 'fe'
```

### Step 3: Update Workflow-Specific Names

#### A. Workflow Name (Line 1)
```yaml
name: Infra - Promote Backend Image to Higher Environments
```

#### B. Repository Dispatch Trigger (Line 13)
```yaml
repository_dispatch:
  types: [ backend-image-promote ]  # ← Change from 'frontend-image-promote'
```

#### C. Workflow Description (Line 7)
```yaml
description: "Full image with digest (e.g., myacr.azurecr.io/raptor/backend-dev@sha256:...)"
```

### Step 4: Search & Replace (Entire File)

Use your editor's find & replace:

| Find | Replace | Count | Impact |
|------|---------|-------|--------|
| `FRONTEND_REPO_READ_TOKEN` | `BACKEND_REPO_READ_TOKEN` | ~12 | Environment var names |
| `frontendFqdn` | `backendFqdn` | ~12 | FQDN output variable |
| `Frontend:` | `Backend:` | ~6 | Display strings |
| `Promote frontend` | `Promote backend` | ~3 | Email subjects |

**Important:** The SERVICE_KEY and SERVICE_SUFFIX changes in Step 2 will automatically handle:
- ✅ App names: `${ENV}-rap-${SERVICE_SUFFIX}` becomes `test-rap-be`
- ✅ Repository parsing: Pattern matches `backend-(dev|test|train|prod)`
- ✅ Repo variable lookup: Looks for `BACKEND_REPO` variable

### Step 5: Verify Critical Sections

After replacement, verify these still work:

1. **Image import sections** (lines ~426, ~853)
   - Should reference `raptor/${{ env.SERVICE_KEY }}-...`
   - Automatically becomes `raptor/backend-test`, etc.

2. **App name construction** (lines ~457, ~883)
   - Should use `${{ env.SERVICE_SUFFIX }}`
   - Automatically becomes `test-rap-be`, etc.

3. **Environment variable names** (lines ~449, ~875)
   - These still need manual bash computation:
   ```bash
   SERVICE_KEY_UPPER=$(echo "${{ env.SERVICE_KEY }}" | tr '[:lower:]' '[:upper:]')
   IMAGE_VAR="SERVICE_${SERVICE_KEY_UPPER}_IMAGE_NAME"
   azd env set "$IMAGE_VAR" "..."
   ```

## 🔍 Testing Checklist

After creating backend workflow:

- [ ] Trigger backend promotion manually
- [ ] Verify correct repository used: `raptor/backend-test`
- [ ] Verify correct app updated: `test-rap-be`
- [ ] Verify correct env var set: `SERVICE_BACKEND_IMAGE_NAME`
- [ ] Verify correct FQDN output: `backendFqdn`
- [ ] Check email notifications have correct subject

## 📊 Summary of Changes

### Completed ✅
- Workflow-level service configuration added
- Repository variable lookup parameterized
- Base environment parsing parameterized

### Remaining (For Duplication) ⚠️
- 12x `FRONTEND_REPO_READ_TOKEN` → `{SERVICE}_REPO_READ_TOKEN`
- 12x `frontendFqdn` → `{service}Fqdn`
- 6x `Frontend:` → `{Service}:`
- 3x `Promote frontend` → `Promote {service}`

### Total Effort
- **Current state:** 70% parameterized (critical path complete)
- **Duplication effort:** ~10 find & replace operations
- **Time estimate:** 15-20 minutes per new service workflow

## 🎯 Recommendation

**Use Strategy 2** (service-specific workflows):
1. Provides good balance between DRY and maintainability
2. Matches pattern established in `infra-azd.yaml`
3. Lower risk of introducing bugs
4. Easier to review and understand
5. Each service team can own their workflow

The shared scripts (`promote-service-image.sh`, `update-containerapp-image.sh`) already handle the complex logic - workflows are just orchestration!

---

**Related Documentation:**
- `docs/INFRA-AZD-PARAMETERIZATION.md` - Similar approach for dev environment
- `docs/MULTI-SERVICE-DEPLOYMENT.md` - General multi-service architecture
- `docs/QUICK-REFERENCE.md` - Command reference for all scripts
