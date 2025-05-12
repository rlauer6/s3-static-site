#!/usr/bin/env bash
# -*- mode: bash; tab-width: 2; -*-
# Request an ACM certificate in the target or another account and set up DNS validation

set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 -d DOMAIN -c CERT_PROFILE -r ROUTE53_PROFILE -z ZONE_DOMAIN

Options:
  -d  Fully qualified domain name (e.g. cpan.openbedrock.net)
  -c  AWS CLI profile for ACM/CloudFront (e.g. account-a)
  -r  AWS CLI profile for Route 53 zone (e.g. account-b)
  -z  Route 53 base domain name (e.g. openbedrock.net)
  -Z  Hosted zone id (optional)

-----
Notes
-----

1. If you do not provide the ROUTE53_PROFILE it is assumed that your
   hosted zone is in the same account where your certificate
   exists. If the certificate is going to be used for a CloudFront
   distribution then the certificate has to be created in them same
   account as your distribution.

2 If you have more than 1 hosted zones with the same name
  (private/pubic), specify the zone id instead of the name)
EOF

  exit 1
 }

# --- parse arguments ---
while getopts "d:c:r:z:Z:h" opt; do
  case $opt in
    d) DOMAIN="$OPTARG" ;;
    c) CERT_PROFILE="$OPTARG" ;;
    r) ROUTE53_PROFILE="$OPTARG" ;;
    z) ZONE_DOMAIN="$OPTARG" ;;
    Z) ZONE_ID="$OPTARG" ;;
    h|*) usage ;;
  esac
done

if [[ -z "${DOMAIN:-}" || -z "${CERT_PROFILE:-}"  || -z "${ZONE_DOMAIN:-}" ]]; then
  usage
fi
ROUTE53_PROFILE=${ROUTE53_PROFILE:-$CERT_PROFILE}

REGION="us-east-1"
TOKEN=$(echo "$DOMAIN" | tr -cd '[:alnum:]')

CERT_ARN=$(aws acm list-certificates --profile "$CERT_PROFILE" \
                --query "CertificateSummaryList[?DomainName=='$DOMAIN']|[0].CertificateArn" \
                 --output text)

if ! test "$CERT_ARN" = "None"; then
    echo "Certificate for $DOMAIN already exists...exiting" >&2
    echo "$CERT_ARN"
    exit 0
fi

CERT_ARN=$(aws acm request-certificate \
  --region "$REGION" \
  --domain-name "$DOMAIN" \
  --validation-method DNS \
  --idempotency-token "$TOKEN" \
  --tags Key=Name,Value="$DOMAIN" \
  --profile "$CERT_PROFILE" \
  --query CertificateArn \
  --output text)

echo "✅ Certificate requested: $CERT_ARN"

# get validation record
sleep 5
RECORD=$(aws acm describe-certificate \
  --region "$REGION" \
  --certificate-arn "$CERT_ARN" \
  --profile "$CERT_PROFILE" \
  --query "Certificate.DomainValidationOptions[0].ResourceRecord" \
  --output json)

NAME=$(echo "$RECORD" | jq -r .Name)
TYPE=$(echo "$RECORD" | jq -r .Type)
VALUE=$(echo "$RECORD" | jq -r .Value)

# get hosted zone id
if test -z "$ZONE_ID"; then
    ZONE_ID=$(aws route53 list-hosted-zones-by-name \
                  --dns-name "$ZONE_DOMAIN" \
                  --profile "$ROUTE53_PROFILE" \
                  --query "HostedZones[0].Id" \
                  --output text)
fi

if [[ -z "$ZONE_ID" ]]; then
  echo "❌ Could not find hosted zone for $ZONE_DOMAIN"
  exit 1
fi

# create CNAME
aws route53 change-resource-record-sets \
  --hosted-zone-id "$ZONE_ID" \
  --profile "$ROUTE53_PROFILE" \
  --change-batch "{
    \"Changes\": [{
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"$NAME\",
        \"Type\": \"$TYPE\",
        \"TTL\": 300,
        \"ResourceRecords\": [{\"Value\": \"$VALUE\"}]
      }
    }]
  }"

echo "🔄 Waiting for ACM certificate to be issued..."

for i in {1..20}; do
  STATUS=$(aws acm describe-certificate \
    --region "$REGION" \
    --certificate-arn "$CERT_ARN" \
    --profile "$CERT_PROFILE" \
    --query "Certificate.Status" \
    --output text)

  echo "[$i] Status: $STATUS"

  if [[ "$STATUS" == "ISSUED" ]]; then
    echo "🎉 Certificate is now valid."
    echo "🔑 Certificate ARN: $CERT_ARN"
    exit 0
  fi

  sleep 10
done

echo "⚠️ Timed out waiting for certificate to issue. Please check validation manually."
exit 1
