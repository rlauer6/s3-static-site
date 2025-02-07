# Building a Secure Private Static Website on AWS - Part I

*...using tools you probably have lying around the shed!*

### Disclaimer

*ChatGPT was used to help construct our implementation and create this
article.*

## Introduction

While much attention is given to dynamic websites with a myriad of
frameworks to help you build them, there are still many uses for the
good 'ol static website. Whether for hosting documentation, internal
portals, or lightweight applications, static sites remain relevant. In
my case, I wanted to host an internal CPAN repository for storing and
serving Perl modules. AWS provides all of the necessary components for
this task but choosing the right approach and configuring it
**securely and automatically** can be a challenge.


Whenever you make an architectural decision where various
approaches are possible, it's a best practice to document that
decision in an Architectural Design Record (ADR). This type of
documentation justifies your design choice, spelling out precisely how
each approach either meets or fails to meet functional or
non-functional requirements. In the first part of this blog series
we'll discuss the alternatives and why we ended up choosing our
CloudFront based approach. This is our ADR.

## Requirements

| | Description      | Notes                                                              |
| ------------ | -----------      | -----                                                              |
| 1.           | HTTPS website    | Will be used internally but we would like secure transport         |
| 2.           | Access           | Can only be accessed from within a private subnet in our VPC       |
| 3.           | Scalable         | Should be able to handle increasing storage without reprovisioning |
| 4.           | Low-cost         | Ideally less than $10/month                                        |
| 5.           | Low-maintenance  | No patching or maintenance of applicaation or configurations       |
| 6.           | Highly available | Should be available 24x7, content should be backed up              |

## Alternative Approaches

Now that we've defined our functional and non-functional requirements
let's look at some approaches we might take in order to create a
secure, scalable, low-cost, low-maintenance static website for hosting
our CPAN repository.

### Use an S3 Website-Enabled Bucket

This solution at first glance seems like the quickest shot on
goal. While S3 does offer a static website hosting feature, it
doesn't support HTTPS by default, which is a major security concern
and doesnot match our requirements. Additionally, website-enabled S3
buckets do not support private access controls - they are inherently
public if enabled. Had we been able to accept an insecure HTTP site
and public access this approach would have been the easiest to
implement. If we wanted to accept public access but required secure
transport we could have used CloudFront with the website enabled
bucket. Almost, but no cigar because we still need to block access to
the bucket from the internet. Since our goal is to create a private
static site, we would need to use CloudFront as a secure, caching
layer in front of S3. This allows us to enforce HTTPS, control access
using Origin Access Control (OAC), and integrate WAF to restrict
access to our VPC.

*Pros:*

* [x] **Quick & Easy Setup** Enables static website hosting with minimal configuration.
* [x] **No Additional Services Needed**  Can serve files directly from S3 without CloudFront.
* [x] **Lower Cost** No CloudFront request or data transfer fees when accessed directly.

*Cons:*

* [ ] **No HTTPS Support**  Does not natively support HTTPS, which is a security concern.
* [ ] **Public by Default**  Cannot enforce private access controls; once enabled, it's accessible to the public.
* [ ] **No Fine-Grained Security**  Lacks built-in protection mechanisms like AWS WAF or OAC.
* [ ] **Not VPC-Restricted**  Cannot natively block access from the public internet while still allowing internal users.

*Analysis:*

While using an S3 website-enabled bucket is the easiest way to host
static content, it **fails to meet security and privacy requirements**
due to **public access** and **lack of HTTPS support**.

### Deploying a Dedicated Web Server

Perhaps the obvious approach to hosting a private static site is to
deploy a dedicated **Apache or Nginx web server** on an **EC2
instance**. This method involves setting up a lightweight Linux
instance, configuring the web server, and implementing a secure upload
mechanism to deploy new content.

*Pros:*

* [x] **Full Control:** **You can customize the web server configuration,
including caching, security settings, and logging.
* [x] **Private Access:** When used with a VPC, the web server can be
accessed only by internal resources.
* [x] **Supports Dynamic Features:** Unlike S3, a traditional web
server allows for features such as authentication, redirects, and
scripting.
* [x] **Simpler Upload Mechanism:** Files can be easily uploaded using
**SCP, rsync, or an automated CI/CD pipeline**.

*Cons:*

* [ ] **Higher Maintenance:** Requires ongoing security patching,
monitoring, and potential instance scaling. 
* [ ] **Single Point of Failure:** Unless deployed in an autoscaling
group, a single EC2 instance introduces availability risks. 
* [ ] **Limited Scalability:** Scaling is manual unless configured with
an ALB (Application Load Balancer) and autoscaling. 

*Analysis:*

Using a dedicated web server is a **viable alternative**
when additional flexibility is needed, but it comes with added
maintenance and cost considerations. Given our requirements for a
**low-maintenance, cost-effective, and scalable solution**, this may
not be the best approach.

### Using a Proxy Server with a VPC Endpoint

A common approach I have used to securely serve static content from an
S3 bucket is to use an internal **proxy server** (such as Nginx or
Apache) running on an **EC2 instance** within a **private VPC**. In
fact, this is the approach I have used to create my own private yum
repository, so I know it would work effectively for my CPAN
repository.  The proxy server retrieves content from an S3 bucket via
a **VPC endpoint**, ensuring that traffic never leaves AWS's internal
network. This approach avoids requires managing an EC2 instance,
handling security updates, and scaling considerations.  Let's look at
the cost of an EC2 based solution.

The following cost estimates are based on AWS pricing for
**us-east-1**:

#### EC2 Cost Calculation (t4g.nano instance)

| Item | Pricing |
| ---- | ------- |
| Instance type: **t4g.nano** (cheapest ARM-based instance) | Hourly cost: **\$0.0052/hour** |
| Monthly usage: **730 hours** (assuming 24/7 uptime) |  (0.0052 x 730 = **\$3.80/month**) |

*Pros:*

* [x] **Predictable costs** No per-request or per-GB transfer fees beyond the instance cost. 
* [x] **Avoids external traffic costs** All traffic remains within the VPC when using a private endpoint. 
* [x] **Full control over the web server** Can customize caching, security, and logging as needed. 

*Cons:*

* [ ] **Higher maintenance** Requires OS updates, security patches, and monitoring. 
* [ ] **Scaling is manual** Requires autoscaling configurations or manual intervention as traffic grows. 
* [ ] **Potential single point of failure** Needs HA (High Availability) setup for reliability. 

*Analysis:*

If predictable costs and full server control are priorities, **EC2 may
be preferable**. However, this solution requires maintenance and may
not scale with heavy traffic. Moreover, to create an HA solution
would require additional AWS resources.

### CloudFront + S3

To create a **secure, scalable, and cost-effective private static
website**, we chose to use **Amazon S3 with CloudFront**. This
architecture allows us to store our static assets in an **S3 bucket**
while **CloudFront acts as a caching and security layer** in front of
it. Unlike enabling public S3 static website hosting, this approach
provides HTTPS support, better scalability, and fine-grained access
control.

CloudFront integrates with **Origin Access Control (OAC)**, ensuring
that the S3 bucket **only** allows access from CloudFront and **not
directly from the internet**. This eliminates the risk of unintended
public exposure while still allowing authorized users to access
content. Additionally, **AWS WAF (Web Application Firewall)** allows
us to **restrict access to only specific IP ranges or VPCs**, adding
another layer of security.

Let's look at costs:

| Item | Cost | Capacity | Total | 
| ---- | ---- | -------- | ----- |
| Data Transfer Out | First 10TB is \$0.085 per GB | 25GB/month of traffic | **Cost for 25GB:** (25 x 0.085 = \$2.13) |
| HTTP Requests | \$0.0000002 per request | 250,000 requests/month | **Cost for requests:** (250,000 x 0.0000002 = \$0.05) |
| | | | **Total CloudFront Cost:** \$2.13 (Data Transfer) + \$0.05 (Requests) = \$2.18/month |

*Pros:*

* [x] **Scales effortlessly** AWS handles scaling automatically based on demand. 
* [x] **Lower maintenance** No need to manage servers or perform security updates. 
* [x] **Includes built-in caching & security** CloudFront integrates WAF and Origin Access Control (OAC). 

*Cons:*

* [ ] **Traffic-based pricing** Costs scale with data transfer and request volume. 
* [ ] **External traffic incurs costs** Data transfer fees apply for internet-accessible sites. 
* [ ] **Less customization** Cannot modify web server settings beyond what CloudFront offers. 

*Analysis:*

And the winner is...**CloudFront + S3!**  Using just a website enabled S3
bucket fails to meet the basic requiredments so let's eliminate that
solution right off the bat.  If predictable costs and full server
control are priorities, Using an EC2 either as a proxy or a full blown
webserver may be preferable. However, for a **low-maintenance,
auto-scaling solution**, **CloudFront + S3** is the superior
choice. EC2 is slightly more expensive but avoids CloudFront's
external traffic costs. Overall, our winning approach is ideal because it
**scales automatically**, reduces **operational overhead**, and
provides **strong security mechanisms** without requiring a dedicated
EC2 instance to serve content.

* **CloudFront scales better** cost remains low per GB served, whereas
EC2 may require scaling for higher traffic.
* **CloudFront includes built-in caching & security**, while EC2
requires maintenance and patching.

## Bash Scripting vs Terraform

Now that we have our agreed upon an approach (the "what") *and*
documented our "architectural decision", it's time to discuss the
"how".  How should we go about constructing our project?  Many
engineers would default to Terraform for this type of automation, but
we had specific reasons for thinking this through and looking at a
different approach. We'd like:

* [x] Full control over execution order (we decide exactly when & how things run).
* [x] Faster iteration (no need to manage Terraform state files).
* [x] No external dependencies—just AWS CLI.
* [x] Simple solution for a one-off project.

### Why Not Terraform?

While Terraform is a popular tool for infrastructure automation, it
introduces several challenges for this specific project. Here's why we
opted for a **Bash script** over Terraform:

* **State Management Complexity**
  
  Terraform relies on **state files** to track infrastructure
  resources, which introduces complexity when running and re-running
  deployments. State corruption or mismanagement can cause
  inconsistencies, making it harder to ensure a seamless
  **idempotent** deployment.

* **Slower Iteration and Debugging**

  Making changes in Terraform requires updating state, planning, and
  applying configurations. In contrast, Bash scripts execute AWS CLI
  commands **immediately**, allowing for rapid testing and debugging
  without the need for state synchronization.

* **Limited Control Over Execution Order**
  
  Terraform follows a **declarative** approach, meaning it determines
  execution order based on dependencies. This can be problematic when
  AWS services have **eventual consistency issues**, requiring retries
  or specific sequencing that Terraform does not handle well natively.
  
* **Overhead for a Simple, Self-Contained Deployment**
  
  For a relatively **straightforward deployment** like a private
  static website, Terraform introduces **unnecessary complexity**. A
  **lightweight Bash script** using AWS CLI is more **portable,
  requires fewer dependencies**, and avoids managing an external
  Terraform state backend.

* **Handling AWS API Throttling**

  AWS imposes API rate limits, and handling these properly requires
  implementing **retry logic**. While Terraform has some built-in
  retries, it is not as flexible as a custom retry mechanism in a Bash
  script, which can incorporate **exponential backoff** or **manual
  intervention** if needed.

* **Less Direct Logging and Error Handling**

  Terraform's logs require additional parsing and interpretation,
  whereas a Bash script can **log every AWS CLI command execution** in
  a simple and structured format. This makes troubleshooting easier,
  especially when dealing with intermittent AWS errors.

### When Terraform Might Be a Better Choice

Although Bash was the right choice for this project, Terraform is
still **useful for more complex infrastructure** where:

*  **Multiple AWS resources must be coordinated** across different environments.
*  **Long-term infrastructure management** is needed with a team-based workflow.
*  **Integrating with existing Terraform deployments** ensures consistency.

For our case, where the goal was **quick, idempotent, and
self-contained automation**, **Bash scripting provided a simpler and
more effective approach**. This approach gave us the best of both
worlds - automation without complexity, while still ensuring idempotency
and security.

---

## Next Steps

In the part of this series, we'll walk through:

1. **The initial challenges we faced** with AWS automation.
2. **How we built the script step by step**.
3. **Ensuring security & access control with WAF**.
4.  **Error handling, logging, and retries**.
5. **How we verified idempotency** and tested it.

*Stay tuned as we break down the process of **building an AWS
automation script that just works™**.*
