#!/usr/bin/env bash
#-*- mode:sh; -*-

########################################################################
get_cloudfront_distribution_by_tag() {
########################################################################
    local tag_value="$1"
    local aws_profile="$2"

    # Get all CloudFront distribution IDs
    local distributions
    distributions=$(aws cloudfront list-distributions \
        --query "DistributionList.Items[*].Id" \
        --output text --profile "$aws_profile" 2>/dev/null || true)

    # Check if no distributions exist
    if [[ -z "$distributions" ]]; then
        echo "❌ No CloudFront distributions found in the account." >&2
        return 1
    fi

    # Loop through each distribution and check its tags
    for distribution_id in $distributions; do
        local tag_name
        tag_name=$(aws cloudfront list-tags-for-resource \
            --resource "arn:aws:cloudfront::$ACCOUNT_ID:distribution/$distribution_id" \
            --query "Tags.Items[?Key=='Name'].Value" \
            --output text --profile "$aws_profile" 2>/dev/null || true)

        if [[ "$tag_name" == "$tag_value" ]]; then
            echo "$distribution_id"
            return 0  # Exit successfully once we find the distribution
        fi
    done

    echo "❌ No CloudFront distribution found with tag Name=$tag_value" >&2
    return 1
}

########################################################################
get_cloudfront_dns_name() {
########################################################################
    local distribution_id="$1"

    aws cloudfront get-distribution \
        --id "$distribution_id" \
        --query "Distribution.DomainName" \
        --output text \
        --profile $AWS_PROFILE
}

########################################################################
usage() {
########################################################################
    echo "Usage: $0 -d DISTRIBUTION_ID -t TAG_VALUE -p AWS_PROFILE -n SUBDOMAIN_NAME -z HOSTED_ZONE"
    echo ""
    echo "Options:"
    echo "  -d    CloudFront distribution ID (e.g., E1XYZABCDEF)**"
    echo "  -p    AWS Profile"
    echo "  -t    Name tag value**"
    echo "  -n    Subdomain name (e.g., cpan.example.com)"
    echo "  -z    Route 53 hosted zone name (e.g., example.com)"
    echo ""
    echo "Example: $0 -t tbc-cpan-mirror -p prod -z treasurersbriefcase.com -n cpan.treasurersbriefcase.com"
    echo ""
    echo "** Provide either the distribution id of the CloudFront distribution or its Name tag"
    exit 1
}

# Cleanup function for temporary files
########################################################################
cleanup() {
########################################################################
    if [[ -n "${TEMP_FILE:-}" ]] && [[ -f "$TEMP_FILE" ]]; then
        rm -f "$TEMP_FILE"
    fi
}

set -euo pipefail

trap cleanup EXIT

# Parse command-line arguments
while getopts "d:p:n:z:a:t:h" opt; do
    case $opt in
        d) DISTRIBUTION_ID="$OPTARG" ;;
        p) AWS_PROFILE="$OPTARG" ;;
        n) SUBDOMAIN_NAME="$OPTARG" ;;
        t) TAG_VALUE="$OPTARG" ;;
        z) HOSTED_ZONE_NAME="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

TAG_VALUE=${TAG_VALUE:-};
DISTRIBUTION_ID=${DISTRIBUTION_ID:-};
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text --profile $AWS_PROFILE)

# Validate required inputs
if [[ -z "$TAG_VALUE$DISTRIBUTION_ID" || -z "${AWS_PROFILE:-}" || -z "${SUBDOMAIN_NAME:-}" || -z "${HOSTED_ZONE_NAME:-}" ]]; then
    echo "❌ Error: Missing required arguments." >&2
    usage
fi

if test -z "$DISTRIBUTION_ID"; then
    DISTRIBUTION_ID=$(get_cloudfront_distribution_by_tag "$TAG_VALUE" "$AWS_PROFILE")
fi

if test -n "$DISTRIBUTION_ID"; then
    echo "✅ Retrieved distribution id ($DISTRIBUTION_ID) from tag Name=$TAG_VALUE"
else
    echo "❌ Error: Could not find distribution id from tag=$TAG_VALUE" >&2
fi

CLOUDFRONT_DNS_NAME=$(get_cloudfront_dns_name "$DISTRIBUTION_ID")
echo "✅ Retrieved DNS name ($CLOUDFRONT_DNS_NAME) from distribution id ($DISTRIBUTION_ID)"

# Get the Hosted Zone ID
HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "$HOSTED_ZONE_NAME" \
    --query "HostedZones[?Config.PrivateZone == \`true\` && Name == \`$HOSTED_ZONE_NAME.\`].Id" \
    --output text --profile "$AWS_PROFILE")

if [[ -z "$HOSTED_ZONE_ID" ]]; then
    echo "❌ Error: Hosted zone '$HOSTED_ZONE_NAME' not found or is not private." >&2
    exit 1
else
    echo "✅ Retrieved hosted zone id ($HOSTED_ZONE_ID) from $HOSTED_ZONE_NAME"
fi


# Check if the alias record already exists
EXISTING_ALIAS=$(aws route53 list-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" \
    --query "ResourceRecordSets[?Name == '$SUBDOMAIN_NAME.'].AliasTarget.DNSName" \
    --output text --profile "$AWS_PROFILE" || true)

if [[ "$EXISTING_ALIAS" == *"$SUBDOMAIN_NAME"* ]]; then
    echo "✅ Alias record already exists for $CLOUDFRONT_DNS_NAME"
    exit 0
fi

# Create a temporary JSON file for the Route 53 change request
TEMP_FILE=$(mktemp)
cat > "$TEMP_FILE" <<EOF
{
    "Comment": "Creating alias for CloudFront distribution",
    "Changes": [
        {
            "Action": "UPSERT",
            "ResourceRecordSet": {
                "Name": "$SUBDOMAIN_NAME",
                "Type": "A",
                "AliasTarget": {
                    "HostedZoneId": "Z2FDTNDATAQYW2",
                    "DNSName": "$CLOUDFRONT_DNS_NAME",
                    "EvaluateTargetHealth": false
                }
            }
        }
    ]
}
EOF

cat $TEMP_FILE

# Apply the DNS alias record change
aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" \
    --change-batch file://"$TEMP_FILE" --profile "$AWS_PROFILE"

echo "✅ Successfully created alias record: $CLOUDFRONT_DNS_NAME → $SUBDOMAIN_NAME"
