#!/usr/bin/env bash
# Patches cargokit's Gradle plugin script for Gradle 9 compatibility.
#
# cargokit (the Gradle/build glue bundled inside irondash_engine_context and
# super_native_extensions — both pulled in transitively by super_clipboard,
# used for rich-paste in the todo editor) calls the Groovy DSL form
# `project.exec { ... }` inside a Task's @TaskAction. Gradle 9 removed
# Project#exec(Closure) outright (it was deprecated since Gradle 7/8 "to make
# writing configuration-cache-compatible code easier" — see Gradle's own
# upgrading_version_8 guide), so building Android on Gradle 9 fails with:
#   "Could not find method exec() for arguments [...] on project ':irondash_engine_context'"
#
# Upstream cargokit hasn't picked up the documented replacement yet (irondash_engine_context
# 0.5.5 is 12mo old, no newer release exists). Gradle's own migration guide's fix is to
# inject the `ExecOperations` service, which "has the same API and can act as a drop-in
# replacement" — so this patches every cargokit/gradle/plugin.gradle found in the resolved
# pub cache: adds an @Inject-annotated `ExecOperations` accessor to CargoKitBuildTask, and
# rewrites both `project.exec {` call sites to `execOperations.exec {`. ExecOperations has
# existed since Gradle 4.8, so this is a safe no-op on any Gradle version, not just 9 —
# nothing else in the file changes.
#
# Idempotent: skips any file that's already patched (or already lacks the
# `project.exec {` pattern entirely, e.g. a future upstream fix landed).
set -euo pipefail

pub_cache="${PUB_CACHE:-$HOME/.pub-cache}"
if [ ! -d "$pub_cache" ]; then
  echo "==> cargokit gradle9 patch: no pub cache at $pub_cache, skipping"
  exit 0
fi

patched_any=0
while IFS= read -r -d '' f; do
  if grep -q 'getExecOperations' "$f"; then
    continue # already patched
  fi
  if ! grep -q 'project\.exec[[:space:]]*{' "$f"; then
    continue # nothing to patch (unexpected shape, or upstream already fixed it)
  fi
  python3 - "$f" <<'PYEOF'
import re
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    text = fh.read()

# 1. Add the imports the injected service needs, right after the existing Os import.
text = text.replace(
    "import org.apache.tools.ant.taskdefs.condition.Os\n",
    "import org.apache.tools.ant.taskdefs.condition.Os\n"
    "import org.gradle.process.ExecOperations\n"
    "import javax.inject.Inject\n",
    1,
)

# 2. Give CargoKitBuildTask an injected ExecOperations accessor (Gradle auto-implements
#    an abstract getter annotated @Inject on an abstract Task subclass — the standard
#    pattern for services that used to be reached via the deprecated Project methods).
text = re.sub(
    r"(abstract class CargoKitBuildTask extends DefaultTask \{\n)",
    r"\1\n    @Inject\n    abstract ExecOperations getExecOperations()\n",
    text,
    count=1,
)

# 3. Route both call sites through the injected service instead of the removed
#    Project#exec(Closure).
text = text.replace("project.exec {", "execOperations.exec {")

with open(path, "w", encoding="utf-8") as fh:
    fh.write(text)
PYEOF
  echo "==> cargokit gradle9 patch: patched $f"
  patched_any=1
done < <(find "$pub_cache" -path '*/cargokit/gradle/plugin.gradle' -print0 2>/dev/null)

if [ "$patched_any" = 0 ]; then
  echo "==> cargokit gradle9 patch: nothing to do (already patched, or no cargokit deps resolved yet — run 'flutter pub get' first)"
fi
