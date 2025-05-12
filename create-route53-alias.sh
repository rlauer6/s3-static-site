#!/usr/bin/env bash
# -*- mode: bash; tab-width: 2; -*-
# Create a Route 53 alias A record pointing to a CloudFront distribution

set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 -d DOMAIN -z ZONE_DOMAIN -c DISTRIBUTION_ID -p CLOUDFRONT_PROFILE -r ROUTE53_PROFILE

Options:

  -d  Fully qualified domain name (e.g. cpan.openbedrock.net)
  -z  Route 53 base domain (e.g. openbedrock.net)
  -c  CloudFront distribution ID
  -p  AWS CLI profile for CloudFront (e.g. account-a)
  -r  AWS CLI profile for Route 53 (e.g. account-b)
EOF
  exit 1
}

# --- parse arguments ---
while getopts "d:z:c:p:r:h" opt; do
  case $opt in
    d) DOMAIN="$OPTARG" ;;
    z) HOSTED_ZONE_DOMAIN="$OPTARG" ;;
    c) DISTRIBUTION_ID="$OPTARG" ;;
    p) CLOUDFRONT_PROFILE="$OPTARG" ;;
    r) ROUTE53_PROFILE="$OPTARG" ;;
    h|*) usage ;;
  esac
done

# --- validate required args ---
if [[ -z "${DOMAIN:-}" || -z "${HOSTED_ZONE_DOMAIN:-}" || -z "${DISTRIBUTION_ID:-}" || -z "${CLOUDFRONT_PROFILE:-}" || -z "${ROUTE53_PROFILE:-}" ]]; then
  usage
fi

# --- get CloudFront domain name ---
CF_DOMAIN=$(aws cloudfront get-distribution \
  --id "$DISTRIBUTION_ID" \
  --profile "$CLOUDFRONT_PROFILE" \
  --query "Distribution.DomainName" \
  --output text)

# --- get hosted zone ID for base domain ---
ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name "$HOSTED_ZONE_DOMAIN" \
  --profile "$ROUTE53_PROFILE" \
  --query "HostedZones[0].Id" \
  --output text)

if [[ -z "$ZONE_ID" ]]; then
  echo "❌ Could not find hosted zone for $HOSTED_ZONE_DOMAIN"
  exit 1
fi

# --- apply Route 53 alias record ---
echo "🛠️ Creating Route 53 alias record for $DOMAIN -> $CF_DOMAIN"

aws route53 change-resource-record-sets \
  --hosted-zone-id "$ZONE_ID" \
  --profile "$ROUTE53_PROFILE" \
  --change-batch "{
    \"Changes\": [{
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"$DOMAIN\",
        \"Type\": \"A\",
        \"AliasTarget\": {
          \"HostedZoneId\": \"Z2FDTNDATAQYW2\",
          \"DNSName\": \"$CF_DOMAIN\",
          \"EvaluateTargetHealth\": false
        }
      }
    }]
  }"

echo "✅ Alias record created: $DOMAIN -> $CF_DOMAIN"
