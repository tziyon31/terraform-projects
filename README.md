# Nginx ALB Private – Terraform Project

This project provisions an AWS infrastructure using **Terraform**:

- A **VPC** with public and private subnets
- A **NAT instance** for private subnets outbound internet access
- An **EC2 instance** in a private subnet running **NGINX** inside Docker
- An **Application Load Balancer (ALB)** in public subnets that forwards HTTP traffic to the private EC2
- Proper **Security Groups** and **IAM roles** for secure access

---

## 📐 Architecture Overview

## 📐 Architecture Overview

```mermaid
flowchart TD
    A[Internet] --> B[ALB<br/>(public subnets, SG: open :80)]
    B --> C[EC2 App Instance<br/>(private subnet, no public IP)]
    C --> D[NAT Instance<br/>(public subnet, SG: allow from VPC)]
    
    subgraph VPC
      B
      C
      D
    end

NAT Instance (public subnet, SG: allow from VPC)

Enables outbound internet for private EC2

Configured with ip_forward + iptables MASQUERADE


---

## 🚀 How It Works

1. **Terraform** creates the network stack (VPC, subnets, route tables, NAT instance, ALB).
2. **User data** on the EC2 app:
   - Installs Docker
   - Runs an NGINX container
   - Serves a simple page:  
     ```
     yo this is nginx
     ```
3. The **ALB** is internet-facing, listening on port 80.
4. Incoming requests go to the **Target Group**, which forwards them to the EC2 in the private subnet.


nginx-alb-private/
├── main.tf # Main Terraform configuration
├── variables.tf # Input variables definition
├── terraform.tfvars # Variable values (gitignored, local only)
├── outputs.tf # Outputs (ALB DNS, private IP)
└── README.md # Project documentation

---

## 📂 Project Structure

