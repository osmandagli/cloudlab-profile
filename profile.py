"""Profile for MoQ experiment on c6620 with Intel E810-C 100GbE and CPU pinning.

Instructions:
Wait for setup to complete on all nodes, then check /local/setup.log on each.
- relay:      MoQ relay, CPU pinned, Flow Director enabled, HT disabled
- publisher:  MoQ publisher client
- subscriber: MoQ subscriber client
"""

import geni.portal as portal
import geni.rspec.pg as rspec

request = portal.context.makeRequestRSpec()

# Relay
relay = request.RawPC("relay")
relay.hardware_type = "c6620"
relay.disk_image = "urn:publicid:IDN+emulab.net+image+emulab-ops//UBUNTU22-64-STD"
relay.addService(rspec.Execute(
    shell="bash",
    command="sudo bash /local/repository/setup.sh relay"
))

# Publisher
publisher = request.RawPC("publisher")
publisher.hardware_type = "c6620"
publisher.disk_image = "urn:publicid:IDN+emulab.net+image+emulab-ops//UBUNTU22-64-STD"
publisher.addService(rspec.Execute(
    shell="bash",
    command="sudo bash /local/repository/setup.sh publisher"
))

# Subscriber 
subscriber = request.RawPC("subscriber")
subscriber.hardware_type = "c6620"
subscriber.disk_image = "urn:publicid:IDN+emulab.net+image+emulab-ops//UBUNTU22-64-STD"
subscriber.addService(rspec.Execute(
    shell="bash",
    command="sudo bash /local/repository/setup.sh subscriber"
))

# Links
link_pub = request.Link(members=[publisher, relay])
link_sub = request.Link(members=[subscriber, relay])

portal.context.printRequestRSpec()
