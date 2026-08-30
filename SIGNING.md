# Image signing and verification

Every published `ghcr.io/blunox-org/runner` image is signed with
[cosign](https://docs.sigstore.dev/), using a key held in a cloud KMS. The private
half never leaves the HSM.

Signatures are **attached to the image**, so verification needs nothing but the
image reference and the public key below — no separate download, no manifest to
fetch, and no network call to a transparency log.

## Status

> **The signing key is not published yet.** Releases are not yet cut against the
> production key, so there is nothing to verify against and this page has no key
> on it. `cosign verify` will fail until it does — that is expected, not a
> tampering signal.
>
> When the first signed release ships, the public key and its SHA-256 fingerprint
> are published here, and this notice is removed. Check the fingerprint against
> the one in your Blunox onboarding material before trusting it.

## Verifying one image

```bash
cosign verify --key blunox.pub ghcr.io/blunox-org/runner:<version>
```

## Enforcing it continuously

A one-off check at install proves nothing about later pulls. To require a valid
signature on every admission, use the Kyverno policy in
[`policy/kyverno-verify-runner.yaml`](policy/kyverno-verify-runner.yaml), or the
equivalent with sigstore-policy-controller.

That is the stronger posture and the one we recommend for production clusters: it
covers node replacements, scale-ups and rollbacks, none of which run your install
command again.

## Reporting a problem

If `cosign verify` fails on a released version once the key is published, stop the
install and contact Blunox support before proceeding. Do not open a public issue
with the details.
