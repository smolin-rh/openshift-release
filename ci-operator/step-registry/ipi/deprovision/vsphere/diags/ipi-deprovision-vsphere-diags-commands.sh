#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "$(date -u --rfc-3339=seconds) - Collecting vCenter performance data and alerts"
echo "$(date -u --rfc-3339=seconds) - sourcing context from vsphere_context.sh..."
# shellcheck source=/dev/null
declare cloud_where_run

source "${SHARED_DIR}/vsphere_context.sh"

function collect_diagnostic_data {
  set +e

  host_metrics="cpu.ready.summation
  cpu.usage.average
  cpu.usagemhz.average
  cpu.coreUtilization.average
  cpu.costop.summation
  cpu.demand.average
  cpu.idle.summation
  cpu.latency.average
  cpu.readiness.average
  cpu.reservedCapacity.average
  cpu.totalCapacity.average
  cpu.utilization.average
  datastore.datastoreIops.average
  datastore.datastoreMaxQueueDepth.latest
  datastore.datastoreReadIops.latest
  datastore.datastoreReadOIO.latest
  datastore.datastoreVMObservedLatency.latest
  datastore.datastoreWriteIops.latest
  datastore.datastoreWriteOIO.latest
  datastore.numberReadAveraged.average
  datastore.numberWriteAveraged.average
  datastore.siocActiveTimePercentage.average
  datastore.sizeNormalizedDatastoreLatency.average
  datastore.totalReadLatency.average
  datastore.totalWriteLatency.average
  disk.deviceLatency.average
  disk.maxQueueDepth.average
  disk.maxTotalLatency.latest
  disk.numberReadAveraged.average
  disk.numberWriteAveraged.average
  disk.usage.average
  mem.consumed.average
  mem.overhead.average
  mem.swapinRate.average
  mem.swapoutRate.average
  mem.usage.average
  mem.vmmemctl.average
  net.usage.average
  sys.uptime.latest"

  vm_metrics="cpu.ready.summation
  cpu.usage.average
  cpu.usagemhz.average
  cpu.readiness.average
  cpu.overlap.summation
  cpu.swapwait.summation
  cpu.system.summation
  cpu.used.summation
  cpu.wait.summation
  cpu.costop.summation
  cpu.demand.average
  cpu.entitlement.latest
  cpu.idle.summation
  cpu.latency.average
  cpu.maxlimited.summation
  cpu.run.summation
  datastore.read.average
  datastore.write.average
  datastore.maxTotalLatency.latest
  datastore.numberReadAveraged.average
  datastore.numberWriteAveraged.average
  datastore.totalReadLatency.average
  datastore.totalWriteLatency.average
  disk.maxTotalLatency.latest
  mem.consumed.average
  mem.overhead.average
  mem.swapinRate.average
  mem.swapoutRate.average
  mem.usage.average
  mem.vmmemctl.average
  net.usage.average
  sys.uptime.latest"

  source "${SHARED_DIR}/govc.sh"
  vcenter_state="${ARTIFACT_DIR}/vcenter_state"
  mkdir "${vcenter_state}"
  unset GOVC_DATACENTER
  unset GOVC_DATASTORE
  unset GOVC_RESOURCE_POOL

  echo "Gathering information from hosts and virtual machines associated with segment"

  JSON_DATA='{"vms": [], "hosts": []}'
  IFS=$'\n' read -d '' -r -a all_hosts <<< "$(govc find . -type h -runtime.powerState poweredOn)"
  IFS=$'\n' read -d '' -r -a networks <<< "$(govc find -type=n -i=true -name ${LEASED_RESOURCE})"
  for network in "${networks[@]}"; do
          
      IFS=$'\n' read -d '' -r -a vms <<< "$(govc find . -type m -runtime.powerState poweredOn -network $network)"            
      if [ -z ${vms:-} ]; then
        govc find . -type m -runtime.powerState poweredOn -network $network
        echo "No VMs found"
        continue
      fi
      for vm in "${vms[@]}"; do        
          datacenter=$(echo "$vm" | cut -d'/' -f 2)
          vm_host="$(govc vm.info -dc="${datacenter}" ${vm} | grep "Host:" | awk -F "Host:         " '{print $2}')"
          
          if [ ! -z "${vm_host}" ]; then
              hostname=$(echo "${vm_host}" | rev | cut -d'/' -f 1 | rev)
              if [ ! -f "${vcenter_state}/${hostname}.metrics.txt" ]; then                  
                  full_hostpath=$(for host in "${all_hosts[@]}"; do echo ${host} | grep ${vm_host}; done)                  
                  if [ -z "${full_hostpath:-}" ]; then
                    continue
                  fi
                  echo "Collecting Host metrics for ${vm_host}"
                  hostname=$(echo "${vm_host}" | rev | cut -d'/' -f 1 | rev)
                  govc metric.sample -dc="${datacenter}" -d=80 -n=180 ${full_hostpath} ${host_metrics} > ${vcenter_state}/${hostname}.metrics.txt
                  govc metric.sample -dc="${datacenter}" -d=80 -n=180 -t=true -json=true ${full_hostpath} ${host_metrics} > ${vcenter_state}/${hostname}.metrics.json
                  govc object.collect -dc="${datacenter}" "${vm_host}" triggeredAlarmState &> "${vcenter_state}/${hostname}_alarms.log"
                  HOST_METRIC_FILE="${hostname}.metrics.json"
                  JSON_DATA=$(echo "${JSON_DATA}" | jq -r --arg file "$HOST_METRIC_FILE" --arg host "$hostname" '.hosts[.hosts | length] |= .+ {"file": $file, "name": $host}')
              fi
          fi
          echo "Collecting VM metrics for ${vm}"
          vmname=$(echo "$vm" | rev | cut -d'/' -f 1 | rev)          
          govc metric.sample -dc="${datacenter}" -d=80 -n=180 $vm ${vm_metrics} > ${vcenter_state}/${vmname}.metrics.txt
          govc metric.sample -dc="${datacenter}" -d=80 -n=180 -t=true -json=true $vm ${vm_metrics} > ${vcenter_state}/${vmname}.metrics.json

          echo "Collecting alarms from ${vm}"
          govc object.collect -dc="${datacenter}" "${vm}" triggeredAlarmState &> "${vcenter_state}/${vmname}_alarms.log"    

          # press ENTER on the console if screensaver is running
          echo "Keystoke enter in ${vmname} console"
          govc vm.keystrokes -dc="${datacenter}" -vm.ipath="${vm}" -c 0x28

          echo "$(date -u --rfc-3339=seconds) - capture console image from $vm"
          govc vm.console -dc="${datacenter}" -vm.ipath="${vm}" -capture "${vcenter_state}/${vmname}.png"

          METRIC_FILE="${vmname}.metrics.json"
          JSON_DATA=$(echo "${JSON_DATA}" | jq -r --arg file "$METRIC_FILE" --arg vm "$vmname" '.vms[.vms | length] |= .+ {"file": $file, "name": $vm}')
      done
  done
  target_hw_version=$(govc vm.info -json=true "${vms[0]}" | jq -r .VirtualMachines[0].Config.Version)
  echo "{\"hw_version\":  \"${target_hw_version}\", \"cloud\": \"${cloud_where_run}\"}" > "${ARTIFACT_DIR}/runtime-config.json"
  echo ${JSON_DATA} > "${vcenter_state}/metric-files.json"

  set -e
}

function write_results_html() {
  # Create diag-results.html
  RESULT_HTML="${ARTIFACT_DIR}/vcenter_state/diag-results.html"
  cat >> ${RESULT_HTML} << EOF
<html lang="en-US">
  <head>
    <meta charset="utf-8">
    <title>vSphere Metrics</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.0.0-beta3/dist/css/bootstrap.min.css" rel="stylesheet" integrity="sha384-eOJMYsd53ii+scO/bJGFsiCZc+5NDVN2yr8+0RDqr0Ql0h+rP48ckxlpbzKgwra6" crossorigin="anonymous">
    <script src="./diag-results.js"></script>
    <style>
  div#nav-col ul {
    list-style: none;
  }
  data {
    display: none;
  }
  #nav-col {
    max-width: 200px;
  }
  span.float-right {
    float: right;
  }
  table {
    font-size: 8pt;
  }
  .chart-container {
    position: relative;
    margin: auto;
    height: 40vh;
    width: 80vw;
  }

    </style>
  </head>
  <body class="bg-secondary">
    <div id="app" class="container-fluid">
     <div class="row mt-2">
      <div class="col-2" id="nav-col">
       <div class="list-group">
        <button v-on:click="changeContent('summary')" class="list-group-item list-group-item-action">
  Summary          </button>
        <button class="list-group-item list-group-item-action" v-on:click="changeContent('vm')">
  Virtual Machines </button>
        <button class="list-group-item list-group-item-action" v-on:click="changeContent('host')">
  Hosts            </button>
         <a href="https://github.com/elmiko/camgi.rs" class="list-group-item list-group-item-action text-center" target="_blank">
         <img src="https://github.com/favicon.ico" alt="GitHub logo" title="Found a bug or issue? Visit this project's git repo.">
        </a>
       </div>
      </div>
      <div class="col-10 bg-white rounded">
       <div id="main-content" class="overflow-auto">
        <span id="content" v-html="content">
        </span>
       </div>
      </div>
     </div>
    </div>
    <data id="summary-data">
      <h1>Summary</h1>
      <hr>
        <dl>
          <dt class="text-light bg-secondary ps-1 mb-1">Info</dt>
          <dd>This report contains metrics for both the Virtual Machines used in the CI tests as well as the hosts the VMs ran on.</dd>
      </dl>
    </data>
    <data id="vm-data">
      <div id="vm-data-content">
        <h1>Virtual Machines</h1>
        <hr>
        <select name="vm-instances" id="vm-instances" class="vm-instances" onchange="loadVMData()"></select>
        <div id="chart-div">
          <div class="chart-container">
            <canvas id="cpu-usage"></canvas>
          </div>
          <div class="chart-container">
            <canvas id="cpu-used-sum"></canvas>
          </div>
          <div class="chart-container">
            <canvas id="readiness"></canvas>
          </div>
          <div class="chart-container">
            <canvas id="latency"></canvas>
          </div>
          <div class="chart-container">
            <canvas id="net-usage-avg"></canvas>
          </div>
          <div class="chart-container">
            <canvas id="mem-usage-avg"></canvas>
          </div>
        </div>
      </div>
    </data>
    <data id="host-data">
      <div id="host-data-content">
        <h1>Hosts</h1>
        <hr>
        <select name="host-instances" id="host-instances" class="host-instances" onchange="loadHostData()"></select>
        <div id="chart-div">
          <div class="chart-container">
            <canvas id="host-cpu-usage-avg"></canvas>
          </div>
          <div class="chart-container">
            <canvas id="host-cpu-readiness"></canvas>
          </div>
        </div>
      </div>
    </data>

    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.0.0-beta3/dist/js/bootstrap.bundle.min.js" integrity="sha384-JEW9xMcG8R+pH31jmWH6WWP0WintQrMb4s7ZOdauHnUtxwoG2vI5DkLtS3qm9Ekf" crossorigin="anonymous">
    </script>
    <script src="https://cdn.jsdelivr.net/npm/vue@2/dist/vue.js">
    </script>
    <script>
// main vue entry point
var app = new Vue({
  el: '#app',
  data: {
    content: '',
    cpuUsageGraph: '',
    cpuUsedSumGraph: '',
    readinessGraph: '',
    latencyGraph: '',
    netUsageAvgGraph: '',
    memUsageAvgGraph: '',
    hostCpuReadinessGraph: '',
    hostCpuUsageAvgGraph: ''
  },
  methods: {
    changeContent: function(target) {
        let newdata = document.getElementById(target + '-data')
        this.content = newdata.innerHTML
    }
  }
})

// adjust the content window size
var maincontent = document.getElementById('main-content')
maincontent.style.height = window.innerHeight - 10

// set the summary page
app.changeContent('summary')
    </script>

    <script>
  getMetricFiles()
  var targetNode = document.getElementById('content');
  var observer = new MutationObserver(function(){
      if (document.getElementById("content").children[0].id == "vm-data-content") {
        createVmGraphs();
        loadVMData();
      }
      if (document.getElementById("content").children[0].id == "host-data-content") {
        createHostGraphs();
        loadHostData();
      }
  });
  observerConfig = {}
  observerConfig.attributes = getBoolean("True");
  observerConfig.childList = getBoolean("True");
  observer.observe(targetNode, observerConfig);
    </script>
  </body>
</html>
EOF
}

function write_results_js() {
  # Create diag-resultss.html
  RESULT_JS="${ARTIFACT_DIR}/vcenter_state/diag-results.js"
  cat >> ${RESULT_JS} << EOF
async function loadMetricData(url) {
  let myjson;
  fetch(url).then(
      function(u){ return u.json(); }
    ).then(
      function(json){
        myjson = json;
      }
    );

  return myjson;
}

function getBoolean(val) {
  return val.toLowerCase() === "True".toLowerCase();
}

async function processMaster(url, metricLabel, chart, prefix) {
  const master0 = await fetch(url).then(
    function(u){ return u.json(); }
  );
  console.log(master0)

  var labels = [];
  var datasets = [];
  var newData = {
    labels: labels,
    datasets: datasets,
  };

  console.log(master0.Sample[0].Value[0].Name);

  // Create labels
  for (dataLabel of master0.Sample[0].SampleInfo) {
    newData.labels.push(dataLabel.Timestamp)
  }

  // Add metrics
  const metrics = master0.Sample[0].Value;
  for (metric of metrics) {
    if (metric.Name === metricLabel) {
      var metricData = {}
      var instance = metric.Instance;
      if (instance === "") {
        instance = "average"
      }
      metricData.label = [prefix, instance].join("");
      metricData.data = metric.Value;

      datasets.push(metricData);
    }
  }

  console.log(newData);
  chart.data = newData;
  chart.update();
}

async function getMetricFiles() {
  const filesInfo = await fetch("./metric-files.json").then(
    function(u){ return u.json(); }
  );

  var selectInput = document.getElementById('vm-instances');
  selectInput.innerHTML = [];

  // Load VM Data Files
  var options = []
  for (vm of filesInfo.vms) {
    console.log(vm)

    var opt = document.createElement('option');

    options.push("<option value='" + vm.file + "'>" + vm.name + "</option>");
  }
  selectInput.innerHTML = options.join();
  //processMaster(filesInfo.files[0].file, Chart.getChart("readiness"));

  // Clear Host List
  var hostInput = document.getElementById('host-instances');
  hostInput.innerHTML = [];

  // Load Host Data Files
  options = []
  for (host of filesInfo.hosts) {
    console.log(host)

    var opt = document.createElement('option');

    options.push("<option value='" + host.file + "'>" + host.name + "</option>");
  }
  hostInput.innerHTML = options.join();
}

function loadVMData() {
  var select = document.getElementById("vm-instances");
  var vmFile = select.value;
  processMaster(vmFile, "cpu.usage.average", this.cpuUsageGraph, "CPU - ");
  processMaster(vmFile, "cpu.used.summation", this.cpuUsedSumGraph, "CPU - ");
  processMaster(vmFile, "cpu.readiness.average", this.readinessGraph, "CPU - ");
  processMaster(vmFile, "disk.maxTotalLatency.latest", this.latencyGraph, "");
  processMaster(vmFile, "net.usage.average", this.netUsageAvgGraph, "NIC - ");
  processMaster(vmFile, "mem.usage.average", this.memUsageAvgGraph, "");
}

function loadHostData() {
  var select = document.getElementById("host-instances");
  var hostFile = select.value;
  console.log(hostFile);
  processMaster(hostFile, "cpu.usage.average", this.hostCpuUsageAvgGraph, "CPU - ");
  processMaster(hostFile, "cpu.readiness.average", this.hostCpuReadinessGraph, "");
}

function getGraphConfig(graphTitle, showLegend) {
  const labels = [];
  const data = {
    labels: labels,
    datasets: []
  };

  var graphConfig = {
    type: 'line',
    data: data,
    options: {
      scales: {
        y: {}
      },
      plugins: {
          legend: {},
          title: {
              text: graphTitle
          }
      }
    }
  };
  graphConfig.options.responsive = getBoolean("True");
  graphConfig.options.maintainAspectRatio = getBoolean("False");
  graphConfig.options.scales.y.beginAtZero = getBoolean("True");
  graphConfig.options.plugins.legend.display = showLegend;
  graphConfig.options.plugins.title.display = getBoolean("True");

  return graphConfig;
}

function createVmGraphs() {
  const cpuUsageCtx = document.getElementById('cpu-usage');
  const cpuUsedSumCtx = document.getElementById('cpu-used-sum');
  const readinessCtx = document.getElementById('readiness');
  const latencyCtx = document.getElementById('latency');
  const netUsageCtx = document.getElementById('net-usage-avg');
  const memUsageCtx = document.getElementById('mem-usage-avg');

  console.log("creating charts")
  this.cpuUsageGraph = new Chart(cpuUsageCtx, getGraphConfig("CPU Usage"));
  this.cpuUsedSumGraph = new Chart(cpuUsedSumCtx, getGraphConfig("CPU Used Summation"));
  this.readinessGraph = new Chart(readinessCtx, getGraphConfig("CPU Readiness"));
  this.latencyGraph = new Chart(latencyCtx, getGraphConfig("Latency"));
  this.netUsageAvgGraph = new Chart(netUsageCtx, getGraphConfig("Net Usage Average"));
  this.memUsageAvgGraph = new Chart(memUsageCtx, getGraphConfig("Memory Usage Average"));
}

function createHostGraphs() {
  const hostCpuUsageAvgCtx = document.getElementById('host-cpu-usage-avg');
  const hostCpuReadinessCtx = document.getElementById('host-cpu-readiness');

  this.hostCpuUsageAvgGraph = new Chart(hostCpuUsageAvgCtx, getGraphConfig("Host CPU Usage Average", getBoolean("False")));
  this.hostCpuReadinessGraph = new Chart(hostCpuReadinessCtx, getGraphConfig("Host CPU Readiness", getBoolean("True")));
}
EOF
}

collect_diagnostic_data
write_results_html
write_results_js
