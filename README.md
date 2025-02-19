# README

This project contains various scripts for working with S3 buckets.

| Name | Description | Blog Post |
| ---- | ----------- | --------- |
| `s3-static-website.sh` | Create a private S3 backed static website | [Hosting a Secure Static Website with S3 and CloundFront](https://blog.tbcdevelopmentgroup.com/2025-02-18-post.html) |
| `s3-bucket-unlock.sh` | Unlock an S3 bucket by updating the bucket policy | [Hosting a Secure Static Website with S3 and CloundFront](https://blog.tbcdevelopmentgroup.com/2025-02-21) | |
| `update-route53.sh` | Update Route 53 | |

# `s3-static-website.sh`

*Creates:*

* ... a new S3 bucket if it does not exist
* ... a CloudFront distribution
* ... an origin access for connecting the distribution to the bucket
* ... WAF rules for locking down your bucket

```
s3-static-website.sh -p my-profile -b bucket-name -c certificate name -a alternate-domain-name
```

```
Usage: ./s3-static-site.sh -b BUCKET_NAME -p AWS_PROFILE [-r AWS_REGION] [-o OAC_NAME]

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
```

# `update-route53` 

Run this script if you want your static bucket to have it's own domain
name.

```
Usage: ./update-route53.sh -d DISTRIBUTION_ID -t TAG_VALUE -p AWS_PROFILE -n SUBDOMAIN_NAME -z HOSTED_ZONE

Options:
  -d    CloudFront distribution ID (e.g., E1XYZABCDEF)**
  -p    AWS Profile
  -t    Name tag value**
  -n    Subdomain name (e.g., cpan.example.com)
  -z    Route 53 hosted zone name (e.g., example.com)

Example: ./update-route53.sh -t tbc-cpan-mirror -p prod -z treasurersbriefcase.com -n cpan.treasurersbriefcase.com

** Provide either the distribution id of the CloudFront distribution or its Name tag
```
