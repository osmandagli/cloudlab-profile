"""Profile for relay on c6620 with Intel E810-C 100GbE and CPU pinning.

Instructions:
Wait for setup to complete, then check /local/setup.log.
The relay is pinned to CPU core 2, Flow Director steers to that core's queue.
HT is disabled via GRUB in setup.sh (requires one automatic reboot).
"""

import geni.portal as portal
import geni.rspec.pg as rspec

request = portal.context.makeRequestRSpec()

node = request.RawPC("node")
node.hardware_type = "c6620"
node.disk_image = "urn:publicid:IDN+emulab.net+image+emulab-ops//UBUNTU22-64-STD"
node.addService(rspec.Execute(
    shell="bash",
    command="sudo /local/repository/setup.sh"
))

portal.context.printRequestRSpec()
