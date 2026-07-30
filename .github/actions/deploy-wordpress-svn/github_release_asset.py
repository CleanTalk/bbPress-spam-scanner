import json
import sys
import urllib.request


def main() -> int:
    if len(sys.argv) != 6:
        raise SystemExit("Usage: github_release_asset.py <repo> <tag> <asset_name> <token> <output_json>")

    repo, tag, asset_name, token, output_json = sys.argv[1:6]
    req = urllib.request.Request(
        f"https://api.github.com/repos/{repo}/releases/tags/{tag}",
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as response:
        payload = json.loads(response.read().decode('utf-8'))

    with open(output_json, 'w', encoding='utf-8') as fh:
        json.dump(payload, fh)

    for asset in payload.get('assets', []):
        if asset.get('name') == asset_name:
            print(asset.get('browser_download_url', ''))
            return 0

    raise SystemExit(f"Asset not found: {asset_name}")


if __name__ == '__main__':
    raise SystemExit(main())
