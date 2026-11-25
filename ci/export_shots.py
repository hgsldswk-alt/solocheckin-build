"""Export all 15 named App Store images and the paywall from xcresult."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
LANGUAGES = ("en", "zh-Hans", "zh-Hant")
SCENES = ("01-home", "02-time", "03-reminder", "04-contacts", "05-travel")
PAID = "paid-01-paywall"
PNG = b"\x89PNG\r\n\x1a\n"
NAME = re.compile(r"^(store-(?:zh-Hans|zh-Hant|en)-\d{2}-[a-z-]+|paid-01-paywall)(?=[_. ]|$)")


def required_names(project=ROOT):
    path = project / "\u4e0a\u67b6\u8d44\u6599" / "\u5546\u5e97\u622a\u56fe.json"
    scenes = tuple(page["shot"] for page in json.loads(path.read_text(encoding="utf-8"))["pages"]) if path.is_file() else SCENES
    return {PAID, *(f"store-{lang}-{scene}" for lang in LANGUAGES for scene in scenes)}


def collect(source_dir, required):
    found = {}
    manifest = json.loads((source_dir / "manifest.json").read_text(encoding="utf-8"))
    for test in manifest:
        for entry in test.get("attachments", []):
            match = NAME.match(entry.get("suggestedHumanReadableName", ""))
            if not match or match[1] not in required:
                continue
            path = (source_dir / entry["exportedFileName"]).resolve()
            if not path.is_relative_to(source_dir.resolve()) or path.suffix.lower() != ".png":
                raise ValueError(f"Invalid attachment path for {match[1]}")
            with path.open("rb") as attachment:
                if attachment.read(len(PNG)) != PNG:
                    raise ValueError(f"Invalid PNG attachment for {match[1]}")
            if match[1] in found:
                raise ValueError(f"Duplicate attachment {match[1]}")
            found[match[1]] = path
    if missing := required - found.keys():
        raise ValueError("Missing attachments: " + ", ".join(sorted(missing)))
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("result")
    parser.add_argument("output", type=Path)
    parser.add_argument("--attachments", action="store_true", help="Read an already exported attachment directory")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(dir=output, prefix="xcresult-") as folder:
            source = Path(args.result).resolve()
            if not args.attachments:
                subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(source),
                                "--output-path", folder], check=True)
                source = Path(folder)
            named = collect(source, required_names())
            for name, path in named.items():
                shutil.copyfile(path, output / f"{name}.png")
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        parser.exit(1, f"{exc}\n")
    listing = ROOT / "\u4e0a\u67b6\u8d44\u6599" / "listing.json"
    if listing.is_file():
        data = json.loads(listing.read_text(encoding="utf-8"))
        for path in {item["reviewScreenshot"] for item in data["iaps"]}:
            target = listing.parent / path
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(output / f"{PAID}.png", target)
    print(f"Exported {len(named)} named screenshots to {output}")


if __name__ == "__main__":
    main()
