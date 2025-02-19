#!/usr/bin/env bash
#-*- mode: sh; -*-

set -o errexit -o nounset -o pipefail

########################################################################
create_s3_bucket() {
########################################################################

    # Check if the bucket already exists
    BUCKET_EXISTS=$(run_command $AWS s3api head-bucket \
                                --bucket $BUCKET_NAME \
                                --profile $AWS_PROFILE || true)

    if echo "$BUCKET_EXISTS" | grep -q '404'; then
        echo "🛠️ Bucket does not exist. Creating..."
        BUCKET_CONFIGURATION=$([ "$AWS_REGION" != "us-east-1" ] && echo "--create-bucket-configuration LocationConstraint=$AWS_REGION" || true)
        run_command $AWS s3api create-bucket \
                    --bucket $BUCKET_NAME \
                    --region $AWS_REGION $BUCKET_CONFIGURATION \
                    --profile $AWS_PROFILE
    elif echo "$BUCKET_EXISTS" | grep -q '403'; then
        echo "❌ Error: Bucket name exists but you do not have permission to access it."
        exit 1
    elif echo "$BUCKET_EXISTS" | grep -q '301'; then
        echo "❌ Error: Bucket exists in a different region. Please check the region."
        exit 1
    else
        echo "✅ Bucket already exists: $BUCKET_NAME" | tee -a "$LOG_FILE"
    fi

    BUCKET_REGION=$(run_command $AWS s3api get-bucket-location \
                         --bucket "$BUCKET_NAME" \
                         --profile "$AWS_PROFILE" \
                         --query "LocationConstraint" \
                         --output text || true)

    echo "[$BUCKET_REGION]"

    if [ "$BUCKET_REGION" = "None" ]; then
        BUCKET_REGION="us-east-1"  # AWS returns null for us-east-1
    fi

    if [ "$BUCKET_REGION" != "$AWS_REGION" ]; then
       echo "❌ Error: Bucket exists, but in a different region ($BUCKET_REGION instead of $AWS_REGION)." | tee -a "$LOG_FILE"
        exit 1
    fi

    # Create JSON file for public access block
    PUBLIC_ACCESS_JSON=$(mktemp)
    TEMP_FILES+=("$PUBLIC_ACCESS_JSON")

    cat > "$PUBLIC_ACCESS_JSON" <<EOF
{
  "BlockPublicAcls": true,
  "IgnorePublicAcls": true,
  "BlockPublicPolicy": true,
  "RestrictPublicBuckets": true
}
EOF

    # Run the command using the JSON file
    run_command $AWS s3api put-public-access-block --bucket $BUCKET_NAME \
                --public-access-block-configuration file://$PUBLIC_ACCESS_JSON \
                --profile $AWS_PROFILE
}

########################################################################
get_vpc_id_by_name() {
########################################################################
    local vpc_name="$1"
    local aws_profile="$2"

    if [[ -z "$vpc_name" || -z "$aws_profile" ]]; then
        echo "❌ Error: VPC Name and AWS Profile are required arguments."
        return 1
    fi

    VPC_ID=$(run_command $AWS ec2 describe-vpcs \
        --filters "Name=tag:Name,Values=$vpc_name" \
        --query "Vpcs[0].VpcId" \
        --output text --profile "$aws_profile" 2>/dev/null)

    if [[ "$VPC_ID" == "None" || -z "$VPC_ID" ]]; then
        echo "❌ Error: No VPC found with Name='$vpc_name'."
        return 1
    fi

    echo "$VPC_ID"
}

########################################################################
# Function to clean up temporary files
########################################################################
cleanup() {
########################################################################
    echo "🧹 Cleaning up temporary files..." | tee -a "$LOG_FILE"
    
    if [[ ${#TEMP_FILES[@]} -ne 0 ]]; then
        for temp_file in "${TEMP_FILES[@]}"; do
            if [[ -f "$temp_file" ]]; then
                rm -f "$temp_file"
                echo "✅ Removed: $temp_file" | tee -a "$LOG_FILE"
            fi
        done
    fi
}

########################################################################
run_command() {
########################################################################
    echo "🔹 Running: $*" >&2
    echo "🔹 Running: $*" >>"$LOG_FILE"

    # Create a temp file to capture stdout
    local stdout_tmp
    stdout_tmp=$(mktemp)

    # Detect if we're capturing output (not running directly in a terminal)
    if [[ -t 1 ]]; then
        # Not capturing → Show stdout live
        "$@" > >(tee "$stdout_tmp" | tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)
    else
        # Capturing → Don't show stdout live; just log it and capture it
        "$@" >"$stdout_tmp" 2> >(tee -a "$LOG_FILE" >&2)
    fi

    local exit_code=${PIPESTATUS[0]}

    # Append stdout to log file
    cat "$stdout_tmp" >>"$LOG_FILE"

    # Capture stdout content into a variable
    local output
    output=$(<"$stdout_tmp")
    rm -f "$stdout_tmp"

    if [ $exit_code -ne 0 ]; then
        echo "❌ ERROR: Command failed: $*" >&2
        echo "❌ ERROR: Command failed: $*" >>"$LOG_FILE"
        echo "🔍 Check logs for details: $LOG_FILE" >&2
        echo "🔍 Check logs for details: $LOG_FILE" >>"$LOG_FILE"
        echo "📌 TIP: Since this script is idempotent, you can re-run it safely to retry." >&2
        echo "📌 TIP: Since this script is idempotent, you can re-run it safely to retry." >>"$LOG_FILE"
        exit 1
    fi

    # Output stdout to the caller without adding a newline
    if [[ ! -t 1 ]]; then
        printf "%s" "$output"
    fi
}

########################################################################
init_log() {
########################################################################

    # Ensure log directory exists
    LOG_DIR="$(pwd)/logs"
    mkdir -p "$LOG_DIR"

    # Generate a unique log file using timestamp + process ID (PID)
    LOG_FILE="$LOG_DIR/deploy_$(date +'%Y%m%d_%H%M%S')_$$.log"

    # Ensure log file exists before creating a symlink
    touch "$LOG_FILE"

    # Remove existing symlink in the CWD if it exists
    if [ -L "./deploy.log" ]; then
        rm "./deploy.log"
    fi

    # Create a new symlink in the current working directory
    ln -s "$LOG_FILE" "./deploy.log"

    echo "✅ Symlink created: ./deploy.log -> $LOG_FILE" | tee -a "$LOG_FILE"
}

########################################################################
# Function to display help message
########################################################################
usage() {
########################################################################

cat <<EOF
Usage: $0 -b BUCKET_NAME -p AWS_PROFILE [-r AWS_REGION] [-o OAC_NAME]

Options:
  -b    (Required) S3 Bucket Name
  -p    (Required) AWS Profile (or set AWS_PROFILE in the environment)
  -r    AWS Region (default: us-east-1)
  -o    CloudFront OAC Name (default: Derived from Bucket Name)
  -a    alternate domain name
  -c    certificate arn
  -i    IP list in CIDR notation of additional public ips
  -h    Display this help message
  -t    Environment tag value (used to find NAT gateway)
  -T    default TTL for CloudFront caching, default: 31536000 (1 year)
  -m    minimum TTL for CloudFront caching, default: 86400 (1 day)
EOF

    exit 1
}

########################################################################
parse_options() {
########################################################################

    # Parse command-line options using `getopt`
    OPTIONS=$(getopt -o b:p:r:o:a:c:i:t:hT:m: --long bucket:,profile:,region:,oac-name:,alt-domain:,cert-arn:,ip-addresses:,help,default-ttl:,max-ttl: -- "$@")
    if [ $? -ne 0 ]; then
        usage
    fi

    eval set -- "$OPTIONS"

    while true; do
        case "$1" in
            -b | --bucket )       BUCKET_NAME="$2"; shift 2 ;;
            -p | --profile )      AWS_PROFILE="$2"; shift 2 ;;
            -r | --region )       AWS_REGION="$2"; shift 2 ;;
            -o | --oac-name )     OAC_NAME="$2"; shift 2 ;;
            -a | --alt-domain )   ALT_DOMAIN="$2"; shift 2 ;;
            -i | --ip-addresses ) IP_ADDRESSES="$2"; shift 2 ;;
            -c | --cert-arn )     CERT_ARN="$2"; shift 2 ;;
            -t | --tag-value )    TAG_VALUE="$2"; shift 2 ;;
            -T | --default-ttl)   DEFAULT_TTL="$2"; shift 2;;
            -m | --max-ttl)       MAX_TTL="$2"; shift 2;;
            -h | --help )        usage ;;
            -- ) shift; break ;;
            * ) break ;;
        esac
    done
}

########################################################################
validate_options() {
########################################################################
    ALT_DOMAIN=${ALT_DOMAIN:-}
    CERT_ARN=${CERT_ARN:-}

    # Validate required inputs
    if [ -z "$BUCKET_NAME" ]; then
        echo "❌ Error: S3 Bucket Name is required." | tee -a "$LOG_FILE"
        usage
    fi

    if [ -z "$AWS_PROFILE" ]; then
        echo "❌ Error: AWS Profile is required. Either pass -p <profile> or set AWS_PROFILE in the environment." | tee -a "$LOG_FILE"
        usage
    fi

    TAG_VALUE=${TAG_VALUE:-$AWS_PROFILE}

    # Derive OAC_NAME from BUCKET_NAME if not provided
    if [ -z "$OAC_NAME" ]; then
        OAC_NAME="${BUCKET_NAME}-OAC"
    fi
}

########################################################################
create_cloudfront_oac() {
########################################################################
    # Create CloudFront Origin Access Control (OAC) using a temp file
    OAC_CONFIG=$(mktemp)
    TEMP_FILES+=("$OAC_CONFIG")

    cat > "$OAC_CONFIG" <<EOF
{
  "Name": "$OAC_NAME",
  "Description": "OAC for Private S3 Website",
  "SigningProtocol": "sigv4",
  "SigningBehavior": "always",
  "OriginAccessControlOriginType": "s3"
}
EOF

    # Check if OAC already exists
    EXISTING_OAC_ID=$(run_command $AWS cloudfront list-origin-access-controls  \
                          --query "OriginAccessControlList.Items[?Name=='$OAC_NAME'].Id" \
                          --output text \
                          --profile $AWS_PROFILE | tee -a $LOG_FILE)

    if [[ -n "$EXISTING_OAC_ID" && "$EXISTING_OAC_ID" != "None" ]]; then
        echo "✅ CloudFront OAC already exists. Using existing OAC ID: $EXISTING_OAC_ID" | tee -a "$LOG_FILE"
        OAC_ID=$EXISTING_OAC_ID
    else
        echo "🛠️ Creating a new CloudFront OAC..." | tee -a "$LOG_FILE"
        OAC_ID=$(run_command $AWS cloudfront create-origin-access-control  \
                     --origin-access-control-config file://$OAC_CONFIG \
                     --query "OriginAccessControl.Id" \
                     --output text \
                     --profile $AWS_PROFILE | tee -a $LOG_FILE )
        
        if [ -z "$OAC_ID" ]; then
            echo "❌ Failed to create CloudFront OAC. Exiting." | tee -a "$LOG_FILE"
            exit 1
        fi
    fi
}

########################################################################
tag_cloudfront_distribution() {
########################################################################
    echo "🛠️ Tagging the CloudFront Distribution..." | tee -a "$LOG_FILE"

    CLOUDFRONT_ARN="arn:aws:cloudfront::$AWS_ACCOUNT:distribution/$DISTRIBUTION_ID"

    # tag the distribution with the bucket name
    run_command $AWS cloudfront tag-resource \
        --resource $CLOUDFRONT_ARN \
        --tags "Items=[{Key=Name,Value=$BUCKET_NAME}]" \
        --profile $AWS_PROFILE 2>>"$LOG_FILE"
}

########################################################################
create_cloudfront_distribution_config() {
########################################################################

    # Create CloudFront Distribution using a temp file
    CF_DISTRIBUTION_CONFIG=$(mktemp)
    TEMP_FILES+=("$CF_DISTRIBUTION_CONFIG")


    if [[ -z "$ALT_DOMAIN" || -z "$CERT_ARN" ]]; then
        echo "❌ Warn: Both --alt-domain and --cert-arn are required for custom SSL setup. Using defaults CloudFront certificate."
        VIEWER_CERTIFICATE=$(
            cat <<'EOF'
"ViewerCertificate": {
    "CloudFrontDefaultCertificate": true,
    "MinimumProtocolVersion": "TLSv1.2_2021",
    "SSLSupportMethod": "vip"
 }
EOF
                          )
    else
        VIEWER_CERTIFICATE=$(
            cat <<EOF
 "ViewerCertificate": {
        "ACMCertificateArn": "$CERT_ARN",
        "SSLSupportMethod": "sni-only",
        "MinimumProtocolVersion": "TLSv1.2_2021"
    }
EOF
                          )
    fi

    if test -n "$ALT_DOMAIN"; then
        ALIASES=$(
            cat <<EOF
  "Aliases": {
    "Quantity": 1,
    "Items": ["$ALT_DOMAIN"]
  },
EOF
               )
    else 
        ALIASES=$(
            cat <<EOF
"Aliases": {
  "Quantity": 0
},
EOF
               )

    fi

    cat <<EOF > "$CF_DISTRIBUTION_CONFIG"
{
  "CallerReference": "$CALLER_REFERENCE",
   $ALIASES
  "Origins": {
    "Quantity": 1,
    "Items": [
      {
        "Id": "S3-$BUCKET_NAME",
        "DomainName": "$BUCKET_NAME.s3.amazonaws.com",
        "OriginAccessControlId": "$OAC_ID",
        "S3OriginConfig": {
          "OriginAccessIdentity": ""
        }
      }
    ]
  },
  "DefaultRootObject": "$ROOT_OBJECT",
  "DefaultCacheBehavior": {
    "TargetOriginId": "S3-$BUCKET_NAME",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": {
      "Quantity": 2,
      "Items": ["GET", "HEAD"]
    },
    "ForwardedValues": {
      "QueryString": false,
      "Cookies": {
        "Forward": "none"
      }
    },
    "MinTTL": 0,
    "DefaultTTL": $DEFAULT_TTL,
    "MaxTTL": $MAX_TTL
  },
  "PriceClass": "PriceClass_100",
  "Comment": "CloudFront Distribution for $ALT_DOMAIN",
  "Enabled": true,
  "HttpVersion": "http2",
  "IsIPV6Enabled": true,
  "Logging": {
    "Enabled": false,
    "IncludeCookies": false,
    "Bucket": "",
    "Prefix": ""
  },
  $VIEWER_CERTIFICATE
}
EOF
}

########################################################################
create_cloudfront_distribution() {
########################################################################

    DEFAULT_TTL=${DEFAULT_TTL:-86400}
    MAX_TTL=${MAX_TTL:-31536000}

    CALLER_REFERENCE=$(date +%s)
    ROOT_OBJECT="index.html"

    create_cloudfront_oac

    query="DistributionList.Items[?Origins.Items[0].DomainName==\`$BUCKET_NAME.s3.amazonaws.com\`].Id" \
    # Check if CloudFront Distribution Already Exists for this S3 Bucket
    EXISTING_DISTRIBUTION_ID=$(run_command $AWS cloudfront list-distributions \
                                    --query $query \
                                    --output text \
                                    --profile $AWS_PROFILE 2>>$LOG_FILE)

    if [ -n "$EXISTING_DISTRIBUTION_ID" ]; then
        echo "✅ CloudFront distribution already exists: $EXISTING_DISTRIBUTION_ID" | tee -a "$LOG_FILE"
        DISTRIBUTION_ID="$EXISTING_DISTRIBUTION_ID"
    else
        create_cloudfront_distribution_config

        echo "🛠️ Creating a new CloudFront Distribution..." | tee -a "$LOG_FILE"
        
        # Create CloudFront Distribution using `run_command`
        DISTRIBUTION_ID=$(run_command $AWS cloudfront create-distribution \
                              --distribution-config file://"$CF_DISTRIBUTION_CONFIG" \
                              --query "Distribution.Id" \
                              --output text \
                              --profile $AWS_PROFILE)

        if [ -z "$DISTRIBUTION_ID" ]; then
            echo "❌ Failed to create CloudFront Distribution. Exiting." | tee -a "$LOG_FILE"
            exit 1
        fi

        echo "✅ Successfully created CloudFront Distribution: $DISTRIBUTION_ID" | tee -a "$LOG_FILE"
    fi

    CF_DOMAIN_NAME=$(run_command $AWS cloudfront get-distribution \
                         --id "$DISTRIBUTION_ID" \
                         --query "Distribution.DomainName" \
                         --output text \
                         --profile "$AWS_PROFILE")
    
    echo "✅ CloudFront Distribution is accessible at: https://$CF_DOMAIN_NAME" | tee -a "$LOG_FILE"
}

########################################################################
update_bucket_policy() {
########################################################################

    EXISTING_POLICY=$(run_command $AWS s3api get-bucket-policy \
                           --bucket "$BUCKET_NAME" \
                           --profile "$AWS_PROFILE" \
                           --output text 2>>$LOG_FILE || true)

    if [ -n "$EXISTING_POLICY" ]; then
        echo "✅ S3 Bucket Policy already exists. Skipping policy application." | tee -a "$LOG_FILE"
    else
        echo "🛠️ Applying S3 Bucket Policy..." | tee -a "$LOG_FILE"

        BUCKET_POLICY=$(mktemp)
        TEMP_FILES+=("$BUCKET_POLICY")

        # Update S3 Bucket Policy to Restrict Access
        echo "🔒 Updating S3 bucket policy to restrict access to CloudFront Distribution..."

        BUCKET_POLICY=$(mktemp)
        cat > "$BUCKET_POLICY" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "cloudfront.amazonaws.com"
      },
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::$BUCKET_NAME/*",
      "Condition": {
        "StringEquals": {
          "AWS:SourceArn": "arn:aws:cloudfront::$AWS_ACCOUNT:distribution/$DISTRIBUTION_ID"
        }
      }
    }
  ]
}
EOF
        run_command $AWS s3api put-bucket-policy \
             --bucket $BUCKET_NAME \
             --policy file://$BUCKET_POLICY \
             --profile $AWS_PROFILE
    fi

}

########################################################################
find_nat_ip() {
########################################################################
    # Get the Public IP of the VPC
    PUBLIC_IP=$(run_command $AWS ec2 describe-nat-gateways \
                            --filter "Name=tag:Environment,Values=$TAG_VALUE" \
                            --query "NatGateways[0].NatGatewayAddresses[0].PublicIp" \
                            --output text \
                            --profile $AWS_PROFILE)

    if test -z "$PUBLIC_IP"; then
        echo "❌ error: NO PUBLIC IP found for $TAG_VALUE." | tee -a "$LOG_FILE"
        exit 1;
    fi
}

########################################################################
create_waf_ipset() {
########################################################################
    
    # Check if WAF IP Set Already Exists..
    # WAF for CloudFront must always be created in us-east-1
    EXISTING_IPSET_ARN=$(run_command $AWS wafv2 list-ip-sets \
                                     --scope CLOUDFRONT \
                                     --region $AWS_REGION \
                                     --query "IPSets[?Name=='AllowVPCOnly'].ARN" \
                                     --output text \
                                     --profile $AWS_PROFILE 2>>$LOG_FILE)

    if [ -n "$EXISTING_IPSET_ARN" ]; then
        echo "✅ WAF IP Set already exists: $EXISTING_IPSET_ARN" | tee -a "$LOG_FILE"
        IPSET_ARN="$EXISTING_IPSET_ARN"
    else
        find_nat_ip

        echo "🛠️ Creating a new WAF IP Set for VPC access..." | tee -a "$LOG_FILE"
        IP_ADDRESSES=$(echo "$PUBLIC_IP $IP_ADDRESSES" | perl -ne 'printf "[%s]", join ",", map { qq{"$_/32"} } grep { !!$_ }  split /\s/;')

        # WAF for CloudFront must always be created in us-east-1
        IPSET_ARN=$(run_command $AWS wafv2 create-ip-set --name "AllowVPCOnly" \
                        --scope CLOUDFRONT \
                        --region "us-east-1" \
                        --addresses "$IP_ADDRESSES" \
                        --ip-address-version IPV4 --query "Summary.ARN" \
                        --output text \
                        --profile $AWS_PROFILE 2>>$LOG_FILE)

        if [ -z "$IPSET_ARN" ]; then
            echo "❌ Failed to create WAF IP Set. Exiting." | tee -a "$LOG_FILE"
            exit 1
        fi
    fi

    echo "⏳ Waiting for WAF IP Set to be available..." | tee -a "$LOG_FILE"

    IP_SET_NAME="AllowVPCOnly"
    SCOPE="CLOUDFRONT"

    # Wait for the IP Set to appear
    echo "Waiting for IP set '$IP_SET_NAME' to be created..."

    while true; do
        # Fetch the IP set ARN

        # WAF for CloudFront must always be created in us-east-1
        IP_SET_ARN=$(run_command $AWS wafv2 list-ip-sets \
                         --scope "$SCOPE" \
                         --region "us-east-1" \
                         --profile "$AWS_PROFILE" \
                         --query "IPSets[?Name=='$IP_SET_NAME'].ARN" \
                         --output text)

        if [[ -n "$IP_SET_ARN" && "$IP_SET_ARN" != "None" ]]; then
            echo "IP Set created! ARN: $IP_SET_ARN"
            break
        fi

        echo "Still waiting for IP set '$IP_SET_NAME'..."
        sleep 5  # Wait for 5 seconds before checking again
    done

    if test -z "$IP_SET_ARN"; then
        echo "❌ Failed to create IP_SET. Exiting." | tee -a "$LOG_FILE"
        exit 1;
    fi
}


########################################################################
create_waf_web_acl_policy() {
########################################################################
    # Create Web ACL JSON Config
    WEB_ACL_JSON=$(mktemp)
    TEMP_FILES+=("$WEB_ACL_JSON")

    cat > "$WEB_ACL_JSON" <<EOF
{
  "Name": "RestrictToVPC",
  "Scope": "CLOUDFRONT",
  "DefaultAction": { "Block": {} },
  "Rules": [
    {
      "Name": "AllowVPCOnly",
      "Priority": 0,
      "Action": { "Allow": {} },
      "Statement": {
        "IPSetReferenceStatement": { "ARN": "$IPSET_ARN" }
      },
      "VisibilityConfig": {
        "SampledRequestsEnabled": true,
        "CloudWatchMetricsEnabled": true,
        "MetricName": "AllowVPCOnly"
      }
    }
  ],
   "VisibilityConfig": {
    "SampledRequestsEnabled": true,
    "CloudWatchMetricsEnabled": true,
    "MetricName": "RestrictToVPC"
  }
}
EOF
}

########################################################################
create_waf_web_acl() {
########################################################################

    # Check if WAF Web ACL Exists or Create a New One

    EXISTING_WEB_ACL_ARN=$(run_command $AWS wafv2 list-web-acls \
                                       --scope CLOUDFRONT \
                                       --region $AWS_REGION \
                                       --query "WebACLs[?Name=='RestrictToVPC'].ARN" \
                                       --output text \
                                       --profile $AWS_PROFILE 2>>$LOG_FILE)

    if [ -n "$EXISTING_WEB_ACL_ARN" ]; then
        echo "✅ WAF Web ACL already exists: $EXISTING_WEB_ACL_ARN" | tee -a "$LOG_FILE"
        WEB_ACL_ARN="$EXISTING_WEB_ACL_ARN"
    else
        create_waf_web_acl_policy

        echo "🛠️ Creating a new WAF Web ACL..." | tee -a "$LOG_FILE"
        WEB_ACL_ARN=$(run_command $AWS wafv2 create-web-acl --cli-input-json file://"$WEB_ACL_JSON" \
                          --query "Summary.ARN" \
                          --output text --profile $AWS_PROFILE)

        if [ -z "$WEB_ACL_ARN" ]; then
            echo "❌ Failed to create WAF Web ACL. Exiting." | tee -a "$LOG_FILE"
            exit 1
        fi
    fi
}

########################################################################
update_cloudfront_distribution() {
########################################################################
    # Attach WAF ACL to CloudFront
    echo "🔄 Retrieving current CloudFront distribution configuration..."

    # Fetch current configuration and extract ETag
    CURRENT_CONFIG=$(run_command $AWS cloudfront get-distribution \
                                 --id "$DISTRIBUTION_ID" \
                                 --profile $AWS_PROFILE )

    ETAG=$(echo "$CURRENT_CONFIG" | jq -r '.ETag')

    # Save DistributionConfig to a temporary file
    CF_CONFIG=$(mktemp)
    TEMP_FILES+=("$CF_CONFIG")

    CF_CONFIG_UPDATED=$(mktemp)
    TEMP_FILES+=("$CF_CONFIG_UPDATED")

    echo "$CURRENT_CONFIG" | jq '.Distribution.DistributionConfig' > $CF_CONFIG

    # Update the Web ACL ARN in the configuration
    jq --arg web_acl_arn "$WEB_ACL_ARN" '.WebACLId = $web_acl_arn' $CF_CONFIG > $CF_CONFIG_UPDATED

    # Update CloudFront distribution with the new Web ACL
    echo "🔄 Updating CloudFront distribution to attach WAF Web ACL..."
    run_command $AWS cloudfront update-distribution \
         --id "$DISTRIBUTION_ID" \
         --if-match "$ETAG" \
         --distribution-config file://$CF_CONFIG_UPDATED \
         --profile $AWS_PROFILE

    echo "✅ Successfully attached WAF Web ACL to CloudFront Distribution: $DISTRIBUTION_ID" | tee -a "$LOG_FILE"
}

########################################################################
# main script starts here
########################################################################

# List of temp files to be cleaned up
TEMP_FILES=()

# Register cleanup function to run on script exit or error
trap cleanup EXIT

init_log

# Default Values
BUCKET_NAME=""
OAC_NAME=""
AWS_PROFILE="${AWS_PROFILE:-}"  # Use environment variable if set
AWS_REGION="us-east-1"

AWS=$(command -v aws)

if test -z "$AWS"; then
    echo "install the aws cli first!"
    exit 1
fi

parse_options "$@"

validate_options

AWS_ACCOUNT=$(run_command $AWS sts get-caller-identity \
                   --query 'Account' \
                   --output text \
                   --profile $AWS_PROFILE)

# Print selected options
echo "🚀 Running script with the following options:" | tee -a "$LOG_FILE"
echo "   📌 AWS Region: $AWS_REGION" | tee -a "$LOG_FILE"
echo "   📌 S3 Bucket: $BUCKET_NAME" | tee -a "$LOG_FILE"
echo "   📌 AWS Profile: $AWS_PROFILE" | tee -a "$LOG_FILE"
echo "   📌 OAC Name: $OAC_NAME" | tee -a "$LOG_FILE"
echo "   📌 Certificate ARN $CERT_ARN" | tee -a "$LOG_FILE"
echo "   📌 Alternate domain name: $ALT_DOMAIN" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# step 1.
create_s3_bucket

# step 2.
create_cloudfront_distribution

# step 3.
update_bucket_policy

# step 4.
create_waf_ipset

# step 5.
create_waf_web_acl

# step 6.
update_cloudfront_distribution

# step 7.
tag_cloudfront_distribution

echo "🚀 Deployment Summary:"
echo "   ✅ S3 Bucket: $BUCKET_NAME"
echo "   ✅ CloudFront Domain: https://$CF_DOMAIN_NAME"
echo "   ✅ CloudFront Distribution ID: $DISTRIBUTION_ID"
echo "   ✅ WAF WebACL ARN: $WEB_ACL_ARN"
