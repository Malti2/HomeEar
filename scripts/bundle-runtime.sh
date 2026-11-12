#!/usr/bin/env bash
# Bundles the pinned Node.js and Poke CLI into HomeEar/Runtime. Shared by every workflow that
# builds the app so the pinned versions and checksums live in exactly one place.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p HomeEar/Runtime
curl -fL --retry 3 https://nodejs.org/dist/v22.23.3/node-v22.23.3-darwin-arm64.tar.gz -o node.tar.gz
echo '23b25245dcfb9af7262f8ff142e9e2e0af025368117329e7a7458a51e5922f53  node.tar.gz' | shasum -a 256 -c -
tar -xOf node.tar.gz node-v22.23.3-darwin-arm64/bin/node > HomeEar/Runtime/node
chmod 755 HomeEar/Runtime/node
curl -fL --retry 3 https://registry.npmjs.org/poke/-/poke-4.0.461.tgz -o poke.tgz
echo 'wQu6NzjOZamS9jmbmZX60BQtGEXgBeU66dwK2cp/xyERdLWaxc+9VXcWfrjH8zvcw/Z1fColWKPSQyBANawPsg==' | openssl base64 -d -A | od -An -tx1 | tr -d ' \n' > expected-sha512
openssl dgst -sha512 -binary poke.tgz | od -An -tx1 | tr -d ' \n' > actual-sha512
diff expected-sha512 actual-sha512
tar -xOf poke.tgz package/dist/cli.cjs > HomeEar/Runtime/poke.cjs
cp Node-LICENSE.txt HomeEar/Runtime/Node-LICENSE.txt
cp LICENSE-THIRD-PARTY.md HomeEar/Runtime/LICENSE-THIRD-PARTY.md
