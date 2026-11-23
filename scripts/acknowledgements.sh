#!/usr/bin/env bash
# Regenerates the app's acknowledgements from
# CollectiveKit/Package.resolved and the app's Package.resolved (which adds the packages
# only the app links, such as Sparkle), the license files of the package checkouts and the
# maintained CollectiveKit/Acknowledgements/acknowledgements.json:
#
#   CollectiveKit/Sources/CollectiveKit/Resources/Acknowledgements.json  (shipped, About pane)
#   THIRD_PARTY_NOTICES.md                                              (repository)
#
# Fails when a pinned package has no metadata or no license text, when the maintained data names
# a package that is not pinned, or when a listed license file is missing.
# Run it after every dependency or scheme change; AcknowledgementsTests fails until you do.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
kit="$root/CollectiveKit"
app_resolved="$root/App/Collective.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
# Where the app's own packages are checked out; ignored by git.
app_checkouts="$root/build/SourcePackages"

checkout_names() {
  python3 -I -c '
import json, sys
for pin in json.load(open(sys.argv[1]))["pins"]:
    print(pin["location"].rstrip("/").split("/")[-1].removesuffix(".git"))
' "$1"
}

# The checkouts carry the license texts; resolve once if they are not there.
while read -r name; do
  if [[ ! -d "$kit/.build/checkouts/$name" ]]; then
    echo "acknowledgements: checkout $name missing, running swift package resolve" >&2
    (cd "$kit" && swift package resolve)
    break
  fi
done < <(checkout_names "$kit/Package.resolved")
while read -r name; do
  if [[ ! -d "$kit/.build/checkouts/$name" && ! -d "$app_checkouts/checkouts/$name" ]]; then
    echo "acknowledgements: checkout $name missing, resolving the app's packages" >&2
    xcodebuild -resolvePackageDependencies -project "$root/App/Collective.xcodeproj" -scheme Collective \
      -clonedSourcePackagesDirPath "$app_checkouts" >/dev/null
    break
  fi
done < <(checkout_names "$app_resolved")

python3 -I - "$root" "$app_resolved" "$app_checkouts/checkouts" <<'PY'
import json
import os
import sys

root, app_resolved, app_checkouts = sys.argv[1:4]
kit = os.path.join(root, "CollectiveKit")
license_files = ["LICENSE", "LICENSE.txt", "LICENSE.md", "COPYING"]
notice_files = ["NOTICE", "NOTICE.txt"]
errors = []


def fail(message):
    errors.append(message)


def read_text(path):
    with open(path, encoding="utf-8") as handle:
        text = handle.read().strip("\n")
    if not text.strip():
        fail(f"empty license text: {os.path.relpath(path, root)}")
    return text


# The kit's pins, then the app's: the app resolves the kit's packages as well, so they must
# agree; the app adds the packages only it links.
pins = {}
for resolved, checkouts in [(os.path.join(kit, "Package.resolved"), os.path.join(kit, ".build", "checkouts")),
                            (app_resolved, app_checkouts)]:
    with open(resolved, encoding="utf-8") as handle:
        for pin in json.load(handle)["pins"]:
            state = pin["state"]
            # Same rule as PackagePin.parse in the kit.
            version = state.get("version") or state["revision"][:7]
            known = pins.get(pin["identity"])
            if known:
                if known["version"] != version:
                    fail(f"package {pin['identity']} is pinned at {known['version']} by the kit but {version} by the app")
                continue
            pins[pin["identity"]] = {
                "version": version,
                "checkout": os.path.join(checkouts, pin["location"].rstrip("/").split("/")[-1].removesuffix(".git")),
            }

with open(os.path.join(kit, "Acknowledgements", "acknowledgements.json"), encoding="utf-8") as handle:
    maintained = json.load(handle)

scheme_ids = sorted(
    name.removesuffix(".yaml")
    for name in os.listdir(os.path.join(kit, "Sources", "CollectiveKit", "Resources", "Schemes"))
    if name.endswith(".yaml")
)

# Titles of the notices file's sections; they must match SettingsText.libraries,
# .fontsAndIcons and .colorSchemes, which title the same sections in the app.
section_titles = {"libraries": "Libraries", "fontsAndIcons": "Fonts and icons", "colorSchemes": "Color schemes"}
for section in maintained["sections"]:
    if section["id"] not in section_titles:
        fail(f"unknown section id {section['id']!r} in acknowledgements.json (known: {', '.join(section_titles)})")

listed_packages = set()
notes = {}
sections = []
for section in maintained["sections"]:
    entries = []
    for item in section["entries"]:
        name = item["name"]
        spdx = item["spdx"]
        if spdx not in maintained["licenses"]:
            fail(f"{name}: no license name for SPDX id {spdx}")
            continue
        texts = []
        scheme_count = None
        version = None
        package = item.get("package")
        if package:
            listed_packages.add(package)
            pin = pins.get(package)
            if pin is None:
                fail(f"{name}: package {package} is listed but not pinned in Package.resolved")
                continue
            version = pin["version"]
            checkout = pin["checkout"]
            found = [f for f in license_files + notice_files if os.path.isfile(os.path.join(checkout, f))]
            if not any(f in license_files for f in found):
                fail(f"{name}: no license file in {os.path.relpath(checkout, root)}")
                continue
            for f in found:
                texts.append({"file": f, "text": read_text(os.path.join(checkout, f))})
        else:
            if "bundledIn" in item:
                host = item["bundledIn"]
                if host not in pins:
                    fail(f"{name}: bundled in {host}, which is not pinned")
                    continue
                host_name = next(
                    e["name"] for s in maintained["sections"] for e in s["entries"] if e.get("package") == host
                )
                version = f"in {host_name} {pins[host]['version']}"
            elif "schemeIDPrefix" in item:
                count = sum(1 for i in scheme_ids if i.startswith(item["schemeIDPrefix"]))
                if count == 0:
                    fail(f"{name}: no bundled scheme starts with {item['schemeIDPrefix']}")
                    continue
                scheme_count = count
            else:
                version = item["version"]
            for relative in item.get("files", []):
                path = os.path.join(root, relative)
                if not os.path.isfile(path):
                    fail(f"{name}: license file {relative} is missing")
                    continue
                texts.append({"file": os.path.basename(relative), "text": read_text(path)})
            if not texts:
                fail(f"{name}: no license text")
                continue
        for text in texts:
            if "```" in text["text"]:
                fail(f"{name}: {text['file']} contains a code fence, which breaks THIRD_PARTY_NOTICES.md")
        entry = {
            "name": name,
            "spdx": spdx,
            "license": maintained["licenses"][spdx],
            "url": item["url"],
        }
        if package:
            entry["package"] = package
        if "schemeIDPrefix" in item:
            entry["schemeIDPrefix"] = item["schemeIDPrefix"]
        # Exactly one of the two: the app renders a count through its catalog.
        if scheme_count is not None:
            entry["schemeCount"] = scheme_count
        else:
            entry["version"] = version
        entry["texts"] = texts
        # Only for THIRD_PARTY_NOTICES.md; the About sheet shows no per-entry note.
        notes[name] = item.get("note")
        entries.append(entry)
    sections.append({"id": section["id"], "entries": entries})

for identity in pins:
    if identity not in listed_packages:
        fail(f"package {identity} is pinned in Package.resolved but has no entry in acknowledgements.json")

if errors:
    for message in errors:
        print(f"acknowledgements: {message}", file=sys.stderr)
    sys.exit(1)

resource = {"generatedBy": "scripts/acknowledgements.sh", "sections": sections}
with open(os.path.join(kit, "Sources", "CollectiveKit", "Resources", "Acknowledgements.json"), "w", encoding="utf-8") as handle:
    json.dump(resource, handle, indent=2, ensure_ascii=False)
    handle.write("\n")

lines = [
    "# Third-Party Notices",
    "",
    "<!-- Generated by scripts/acknowledgements.sh from CollectiveKit/Package.resolved, the app's",
    "     Package.resolved and CollectiveKit/Acknowledgements/acknowledgements.json. Do not edit by hand. -->",
    "",
    "The Collective includes the following third-party material. The app ships the same texts",
    "(Settings › About › Show License Texts…).",
]
for section in sections:
    lines += ["", f"## {section_titles[section['id']]}"]
    for entry in section["entries"]:
        label = f"{entry['schemeCount']} scheme{'' if entry['schemeCount'] == 1 else 's'}" if "schemeCount" in entry else entry["version"]
        lines += ["", f"### {entry['name']} {label}", "", f"{entry['license']} (`{entry['spdx']}`) · <{entry['url']}>"]
        if notes.get(entry["name"]):
            lines += ["", notes[entry["name"]]]
        for text in entry["texts"]:
            lines += ["", f"`{text['file']}`:", "", "```", text["text"], "```"]
with open(os.path.join(root, "THIRD_PARTY_NOTICES.md"), "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines) + "\n")
PY

echo "acknowledgements: wrote CollectiveKit/Sources/CollectiveKit/Resources/Acknowledgements.json and THIRD_PARTY_NOTICES.md"
