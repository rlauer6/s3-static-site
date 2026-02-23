#!/usr/bin/env bash
# -*- mode: sh; -*-

set -eou pipefail

########################################################################
usage() {
########################################################################
    cat <<EOF
Usage: $0 -i <home-ip> -b <bucket-name> [-v <vpc-id>] [-p <aws-profile>] [-n]

  -i  <home-ip> Your home IP address (e.g., 203.0.113.25)
  -b  <bucket>  S3 bucket name
  -v  <vpc-id>  Optional: VPC ID (auto-detected if running on EC2)
  -p  <profile> Optional: AWS CLI profile (sets AWS_PROFILE environment variable)
  -n            Dry run (show policy, do not apply)

Notes
-----
1. If you do not supply a vpc-id it will be auto-detected if you are running on EC2
2. You *MUST* supply a home-ip value if you are running this script from the VPC
3. The default profile is "default. Use -p to set the profile.
4. **CAUTION** - you can easily lock yourself out of the bucket by applying incorrect IP addresses

Examples
--------
* Running from an EC2:

 ./s3-bucket-unlock.sh -i 67.212.62.134  -b blog-staging.tbcdevelopmentgroup.com -p prod

* Running from outside an EC2

 ./s3-bucket-unlock.sh -v vpc-9526f0ee -b blog-staging.tbcdevelopmentgroup.com -p prod 

EOF
    exit 1
}

########################################################################
# MAIN SCRIPT STARTS HERE
########################################################################

HOME_IP=""
BUCKET=""
VPC_ID=""
PROFILE=""
DRY_RUN=""

AWS=$(command -v aws)

if test -z "$AWS"; then
    echo "error: install 'aws' CLI or make sure it's in your PATH"
    exit 1
fi

CURL=$(command -v curl)

if test -z "$CURL"; then
    echo "error: install 'curl' or make sure it's in your PATH"
    exit 1
fi

while getopts ":i:b:v:p:n" opt; do
  case ${opt} in
    i ) HOME_IP="$OPTARG" ;;
    b ) BUCKET="$OPTARG" ;;
    v ) VPC_ID="$OPTARG" ;;
    p ) PROFILE="$OPTARG" ;;
    n ) DRY_RUN="1" ;;
    * ) usage ;;
  esac
done

if [[ -z "$BUCKET" ]]; then
    usage
fi

if [[ -n "$PROFILE" ]]; then
    export AWS_PROFILE="$PROFILE"
    echo "Using AWS_PROFILE=$AWS_PROFILE"
fi

if [[ -z "$VPC_ID" ]]; then
    # Attempt to get VPC ID from instance metadata (if running on EC2)
    # 1. Get the session token
    TOKEN=$($CURL -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

    # 2. Use the token to access metadata
    if $CURL -s --max-time 2 -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/ >/dev/null; then
        MAC=$($CURL -s -H "X-aws-ec2-metadata-token: $TOKEN"  http://169.254.169.254/latest/meta-data/network/interfaces/macs/)
        VPC_ID=$($CURL -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/network/interfaces/macs/${MAC}vpc-id)
        echo "Detected VPC ID from instance metadata: $VPC_ID"
    fi

    if [[ -z "$VPC_ID" ]]; then
        echo "ERROR: No VPC ID provided and not running on EC2. Exiting."
        exit 1
    fi

    if [[ -z "$HOME_IP" ]]; then
        echo "You must be running on an EC2, so provide your HOME IP otherwise"
        echo "you'll only be allowing access to your NAT gateway's external IP"
        echo "address!"

        usage
    fi
fi

if [[ -z "$HOME_IP" ]]; then
    HOME_IP=$($CURL -s https://checkip.amazonaws.com)
fi

POLICY=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowVPCAndHomeAccess",
            "Effect": "Allow",
            "Principal": "*",
            "Action": ["s3:ListBucket", "s3:GetObject"],
            "Resource": [
                "arn:aws:s3:::$BUCKET",
                "arn:aws:s3:::$BUCKET/*"
            ],
            "Condition": {
                "IpAddressIfExists": { "aws:SourceIp": ["$HOME_IP/32"] },
                "StringEqualsIfExists": { "aws:SourceVpc": "$VPC_ID" }
            }
        },
        {
            "Sid": "AllowHomeAndVPCPolicyUpdate",
            "Effect": "Allow",
            "Principal": "*",
            "Action": "s3:PutBucketPolicy",
            "Resource": "arn:aws:s3:::$BUCKET",
            "Condition": {
                "IpAddressIfExists": { "aws:SourceIp": ["$HOME_IP/32"] },
                "StringEqualsIfExists": { "aws:SourceVpc": "$VPC_ID" }
            }
        },
        {
         "Sid": "DenyAllOthers",
         "Effect": "Deny",
         "Principal": "*",
         "Action": "s3:*",
         "Resource": [
            "arn:aws:s3:::$BUCKET",
            "arn:aws:s3:::$BUCKET/*"
            ],
         "Condition": {
         "StringNotEqualsIfExists": { "aws:SourceVpc": "$VPC_ID" },
         "NotIpAddressIfExists": { "aws:SourceIp": ["$HOME_IP/32"] }
        }
       }
   ]
}
EOF
)

policy=$(mktemp)
trap 'rm -f "$policy"' EXIT INT TERM HUP

echo $POLICY > $policy;
echo $policy;

if test -n "$DRY_RUN"; then
    echo "Dry run mode enabled. Policy would be:"
    echo "$POLICY"
else
    $AWS s3api put-bucket-policy --bucket "$BUCKET" --profile ${PROFILE:-default} --policy file://$policy
    echo "Policy applied to bucket $BUCKET."
    cat $policy
fi
