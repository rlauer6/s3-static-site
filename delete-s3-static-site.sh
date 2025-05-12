#!/usr/bin/env bash
# -*- mode: bash; tab-width: 2; -*-
# Delete Route 53 alias A record pointing to a CloudFront distribution

set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 -d DOMAIN -z ZONE_DOMAIN -c CLOUDFRONT_ID -r ROUTE53_PROFILE -p CLOUDFRONT_PROFILE

-------
Options
-------
  -b  Bucket name (optional) - Will remove bucket if provide, but your bucket must be empty first!
  -d  Fully qualified domain name associated with your distribution (e.g. cpan.openbedrock.net)
  -z  Route 53 hosted zone name (e.g. openbedrock.net)
  -c  CloudFront distribution ID (e.g. E1XXXXXX)
  -r  AWS CLI profile for Route 53 (e.g. account-b)
  -p  AWS CLI profile for CloudFront (e.g. account-a)

-----
Notes
-----
1. Set -r if your Route53 hosted zones are in a different account than your CloudFront distribution
2. This script will attempt to delete your bucket! It will fail if you still have objects in the bucket.
3. This script will NOT remove your certificate if you have one associated with your distribution
EOF
  exit 1
}

while getopts "d:b:z:c:r:p:h" opt; do
  case $opt in
    d) DOMAIN="$OPTARG" ;;
    b) BUCKET="$OPTARG" ;;
    z) ZONE_DOMAIN="$OPTARG" ;;
    c) CLOUDFRONT_ID="$OPTARG" ;;
    r) ROUTE53_PROFILE="$OPTARG" ;;
    p) CLOUDFRONT_PROFILE="$OPTARG" ;;
    h|*) usage ;;
  esac
done

BUCKET=${BUCKET:-}

if [[ -z "${DOMAIN:-}" || -z "${ZONE_DOMAIN:-}" || -z "${CLOUDFRONT_ID:-}" || -z "${CLOUDFRONT_PROFILE:-}" ]]; then
  echo "Missing required arguments:" >&2

  echo "            DOMAIN: ${DOMAIN:*******}"
  echo "       ZONE_DOMAIN: ${ZONE_DOMAIN:-}"
  echo "     CLOUDFRONT_ID: ${CLOUDFRONT_ID:-}"
  echo "CLOUDFRONT_PROFILE: ${CLOUDFRONT_PROFILE:-}"

  usage
fi

if test -n "$BUCKET"; then
 content=$(aws s3 ls s3://$BUCKET/ --profile $CLOUDFRONT_PROFILE);
 if test -n "$content"; then
     echo "Bucket ($BUCKET) must be empty!" >&2
     exit 1;
 fi
fi

ROUTE53_PROFILE=${ROUTE53_PROFILE:-$CLOUDFRONT_PROFILE}

# Get CloudFront domain name (before we delete it)
CF_DOMAIN=$(aws cloudfront get-distribution \
  --id "$CLOUDFRONT_ID" \
  --profile "$CLOUDFRONT_PROFILE" \
  --query "Distribution.DomainName" \
  --output text 2>/dev/null) || true

AWS_ACCOUNT=$(aws sts get-caller-identity --profile $CLOUDFRONT_PROFILE | jq -r .Account)

if test -z "$CF_DOMAIN"; then
    echo "No such distribution ($CLOUDFRONT_ID) for account '$AWS_ACCOUNT'" >&2
    exit 1
fi

config_enabled=$(mktemp)
config_disabled=$(mktemp)

# ensure temp files are removed at exit
trap 'rm -f "$config_enabled" "$config_disabled"' EXIT

# Get distribution configuration and update Enabled to false
aws cloudfront get-distribution-config --id $CLOUDFRONT_ID \
    --profile $CLOUDFRONT_PROFILE | jq -r .DistributionConfig > $config_enabled

jq '.Enabled = false' $config_enabled > $config_disabled

if ! aws cloudfront update-distribution \
  --id $CLOUDFRONT_ID --profile $CLOUDFRONT_PROFILE --no-paginate \
  --if-match "$(aws cloudfront get-distribution --id $CLOUDFRONT_ID --query ETag --output text)" \
  --distribution-config file://$config_disabled > /dev/null ; then
    echo "Failed to update distribution" >&2
    exit 1
fi

# wait for CloudFront distribution to get updated
for a in {1..20}; do
    status=$(aws cloudfront get-distribution \
                 --id $CLOUDFRONT_ID \
                 --profile "$CLOUDFRONT_PROFILE" \
                 --query "Distribution.{Status: Status, Enabled: DistributionConfig.Enabled}" | jq -r .Status)

    if test "$status" = "Deployed"; then
        break;
    fi
    
    echo "Waiting for status ($status) = Deployed..."
    sleep 15
done

if ! test $status = "Deployed"; then
    echo "Timed out waiting for Deployed status" >&2
    exit 1
fi

# delete distribution
if ! aws cloudfront delete-distribution \
       --id $CLOUDFRONT_ID --profile $CLOUDFRONT_PROFILE \
       --if-match "$(aws cloudfront get-distribution-config --id $CLOUDFRONT_ID --query ETag --profile $CLOUDFRONT_PROFILE --output text)"; then
    echo "Failed to delete distribution" >&2
    exit 1
fi

echo "Cloudfront distribution deleted."

if test -n "$BUCKET"; then
    # remove bucket only if above succeeds...assume it is in the CLOUDFRONT_PROFILE account?
    aws s3 rb s3://$BUCKET --profile $CLOUDFRONT_PROFILE
    echo "S3 bucket ($BUCKET) removed"
fi

# Get hosted zone ID
ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name "$ZONE_DOMAIN" \
  --profile "$ROUTE53_PROFILE" \
  --query "HostedZones[?Name=='$ZONE_DOMAIN.'].Id | [0]" \
  --output text)

ZONE_ID=$(basename "$ZONE_ID")

if [[ -z "$ZONE_ID" ]]; then
  echo "Could not find hosted zone for $ZONE_DOMAIN"
  exit 1
fi

# Delete alias record
aws route53 change-resource-record-sets \
  --hosted-zone-id "$ZONE_ID" \
  --profile "$ROUTE53_PROFILE" \
  --change-batch "{
    \"Changes\": [{
      \"Action\": \"DELETE\",
      \"ResourceRecordSet\": {
        \"Name\": \"$DOMAIN.\",
        \"Type\": \"A\",
        \"AliasTarget\": {
          \"HostedZoneId\": \"Z2FDTNDATAQYW2\",
          \"DNSName\": \"$CF_DOMAIN\",
          \"EvaluateTargetHealth\": false
        }
      }
    }]
  }"

echo "Deleted Route 53 alias A record: $DOMAIN -> $CF_DOMAIN"
