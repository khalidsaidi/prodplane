import argparse
import json
import sys
import shlex
from pathlib import Path

DATA_FILE = Path(__file__).with_name('route_records.json')

def choose_domain(records_file):
    with open(records_file, "r") as f:
        records = json.load(f)

    domains = list(records.keys())

    print("Choisissez un domaine :")
    for i, domain in enumerate(domains, start=1):
        print(f"{i}. {domain}")

    while True:
        try:
            choice = int(input("Numéro du domaine: "))
            if 1 <= choice <= len(domains):
                return domains[choice - 1], records[domains[choice - 1]]
            else:
                print("Choix invalide.")
        except ValueError:
            print("Veuillez entrer un nombre.")

def list_load_balancers():
    import boto3
    client_elbv2 = boto3.client("elbv2")
    client_elb = boto3.client("elb")

    loadbalancers = []

    # ALB / NLB
    paginator_v2 = client_elbv2.get_paginator("describe_load_balancers")
    for page in paginator_v2.paginate():
        for lb in page["LoadBalancers"]:
            loadbalancers.append({
                "name": lb["LoadBalancerName"],
                "dns": lb["DNSName"],
                "zone": lb["CanonicalHostedZoneId"],
                "type": lb["Type"],
                "vpc": lb["VpcId"],
                "engine": "elbv2"
            })

    # CLB
    paginator_v1 = client_elb.get_paginator("describe_load_balancers")
    for page in paginator_v1.paginate():
        for lb in page["LoadBalancerDescriptions"]:
            loadbalancers.append({
                "name": lb["LoadBalancerName"],
                "dns": lb["DNSName"],
                "zone": lb["CanonicalHostedZoneNameID"],
                "type": "classic",
                "vpc": lb.get("VPCId"),
                "engine": "elb"
            })

    return loadbalancers

def choose_load_balancer(loadbalancers):
    print("\n=== Liste des Load Balancers disponibles ===\n")
    for idx, lb in enumerate(loadbalancers, 1):
        print(f"{idx}. {lb['name']} ({lb['type']})")
        print(f"   DNS : {lb['dns']}")
        print(f"   HostedZoneId: {lb['zone']}")
        print(f"   VPC: {lb['vpc']}\n")

    choice = int(input("Choisissez un load balancer par numéro : "))
    if 1 <= choice <= len(loadbalancers):
        return loadbalancers[choice - 1]
    else:
        print("Choix invalide.")
        return None

def get_hosted_zone_id(domain_name, hosted_zone_id=None):
    import boto3
    client = boto3.client("route53")
    domain = domain_name.rstrip(".").lower()
    if not domain:
        raise ValueError("A hosted-zone domain name is required.")

    if hosted_zone_id is not None:
        zone_id = hosted_zone_id.removeprefix("/hostedzone/")
        if not zone_id:
            raise ValueError("A non-empty hosted-zone ID is required.")
        zone = client.get_hosted_zone(Id=zone_id)["HostedZone"]
        if zone["Name"].rstrip(".").lower() != domain:
            raise ValueError(f"Hosted zone {zone_id} does not belong to {domain_name}.")
        return zone["Id"].split("/")[-1]

    # Equal DNS names are adjacent, but may span a page boundary. A name alone
    # must never choose between public/private or duplicate hosted zones.
    query = {"DNSName": domain + ".", "MaxItems": "2"}
    matches = []
    while True:
        response = client.list_hosted_zones_by_name(**query)
        for zone in response.get("HostedZones", []):
            if zone["Name"].rstrip(".").lower() == domain:
                matches.append(zone)
                if len(matches) > 1:
                    choices = ", ".join(
                        z["Id"].split("/")[-1] + (" (private)" if z.get("Config", {}).get("PrivateZone") else " (public)")
                        for z in matches
                    )
                    raise ValueError(f"Multiple hosted zones match {domain_name}, including {choices}. Supply --hosted-zone-id.")
        if not response.get("IsTruncated") or response["NextDNSName"].rstrip(".").lower() != domain:
            break
        query = {"DNSName": response["NextDNSName"], "HostedZoneId": response["NextHostedZoneId"], "MaxItems": "2"}

    if not matches:
        raise ValueError(f"No hosted zone exactly matches {domain_name}.")
    return matches[0]["Id"].split("/")[-1]

def generate_aws_commands(domain_name, subdomains, lb_dns, elb_zone_id, hosted_zone_id):
    domain = domain_name.rstrip(".").lower()
    if not domain or not isinstance(subdomains, list):
        raise ValueError("Supply a hosted-zone name and a list of fully qualified record names.")
    commands = []
    for sub in subdomains:
        if not isinstance(sub, str):
            raise ValueError("Record names must be strings.")
        record = sub.rstrip(".").lower()
        if record != domain and not record.endswith("." + domain):
            raise ValueError(f"Record {sub!r} is outside the selected hosted zone {domain_name}.")
        change_batch = {
            "Comment": f"Update {sub} A record to new ELB",
            "Changes": [
                {
                    "Action": "UPSERT",
                    "ResourceRecordSet": {
                        "Name": sub,
                        "Type": "A",
                        "AliasTarget": {
                            "HostedZoneId": elb_zone_id,
                            "DNSName": lb_dns,
                            "EvaluateTargetHealth": False
                        }
                    }
                }
            ]
        }
        # Convertir le dict en JSON compact pour la CLI
        json_str = json.dumps(change_batch)
        # Échapper les quotes pour bash
        json_str_escaped = shlex.quote(json_str)
        cmd = f"aws route53 change-resource-record-sets --hosted-zone-id {shlex.quote(hosted_zone_id)} --change-batch {json_str_escaped}"
        commands.append(cmd)
    return commands

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Generate Route53 alias commands from an operator-supplied domain inventory.")
    parser.add_argument('--records', type=Path, default=DATA_FILE)
    parser.add_argument('--hosted-zone-id', help='Select an exact hosted zone when its name is ambiguous.')
    args = parser.parse_args()
    if not args.records.is_file():
        parser.error('Supply --records FILE, or configure route_records.json from route_records.json.example.')
    domain, subdomains = choose_domain(args.records)
    try:
        hosted_zone_id = get_hosted_zone_id(domain, args.hosted_zone_id)
    except ValueError as error:
        parser.error(str(error))
    lbs = list_load_balancers()
    if not lbs:
        print("Aucun load balancer trouvé.")
        sys.exit(0)

    selected_lb = choose_load_balancer(lbs)
    if selected_lb is None:
        sys.exit(2)

    lb_dns_dualstack = selected_lb['dns']

    if selected_lb['type'] == 'application' and not lb_dns_dualstack.startswith("dualstack."):
        lb_dns_dualstack = "dualstack." + lb_dns_dualstack

    try:
        cmds = generate_aws_commands(domain, subdomains, lb_dns_dualstack, selected_lb['zone'], hosted_zone_id)
    except ValueError as error:
        parser.error(str(error))

    print("\n=== Commandes AWS générées ===\n")
    for c in cmds:
        print(c)
