import os,json
from datetime import datetime
from flask import Flask,Response
from flask import request as flask_request
from google.cloud import bigquery

client = bigquery.Client()
run_date = datetime.today().strftime('%Y-%m-%d')

app = Flask(__name__)

@app.route('/', methods=['POST', 'OPTIONS'])
def run():
    if flask_request.method == 'POST':
        content = flask_request.get_json()
        projects = content['projects']
        table_id = content['table_id']
        for project in projects:
            print(run_date, 'Collecting VM info for project: ', project)
            instances = list_instances(project)
            print(len(instances), ' instances info collected')
            # print(instances)
            for ins in batch(instances, 500):
                errors = client.insert_rows_json(table_id, ins)
            if errors == []:
                print('New rows have been added.')
            else:
                print('Encountered errors while inserting rows: {}'.format(errors))
        return "200"

if __name__ == "__main__":
    app.run(debug=False, host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))


def get_vm_spec(vm_type):
    parts = vm_type.split('-')
    num_parts = len(parts)
    family = parts[0]
    if family == 'custom':
        family = 'n1'
    if parts[0] == 'custom':
        cpu = int(parts[1])
    else:
        cpu = int(parts[2]) if num_parts > 2 else 0
    model = 'custom' if parts[0] == 'custom' else parts[1]
    mem = 0
    if num_parts == 2:
        if family == 'f1': 
            cpu = 1
            mem = 0.6
        elif family == 'g1':
            cpu = 1
            mem = 1.7
        elif family == 'e2':
            if model == 'micro':
                cpu = 2
                mem = 1
            elif model == 'small':
                cpu = 2
                mem = 2
            elif model == 'medium':
                cpu = 2
                mem = 4
    elif num_parts == 3:
        if parts[0] == 'custom':
            mem = float(parts[2])/1024
        else:
            if family == 'n1':
                if model == 'standard':
                    mem = 3.75*cpu
                elif model == 'highmem':
                    mem = 6.5*cpu
                elif model == 'highcpu':
                    mem = 0.9*cpu
            elif family in ['e2', 'n2', 'n2d', 'c2', 'c2d', 't2d']:
                if model == 'standard':
                    mem = 4*cpu
                elif model == 'highmem':
                    mem = 8*cpu
                elif model == 'highcpu':
                    mem = cpu
            elif family == 'm1':
                if model == 'megamem':
                    mem = 14.9*cpu
                elif model == 'ultramem':
                    mem = 24*cpu
    elif num_parts == 4:
        if parts[0] == 'custom': #custom-32-131072-ext
            cpu = parts[1]
            mem = float(parts[2])/1024
        else:
            mem = float(parts[3])/1024
    elif num_parts == 5: #n2-custom-32-131072-ext
        cpu = parts[2]
        mem = float(parts[3])/1024
    return family, cpu, mem

def get_instance(project_id,d):
    # print('======raw data=====\n', d, '\n===============\n')
    nics = []
    for n in d['networkInterfaces']:
        if 'accessConfigs' not in n: #VM with only private IP
            nic = {
                'network': n['network'].split('/')[-1],
                'subnetwork' : n['subnetwork'].split('/')[-1],
                'networkIP': n['networkIP'],
                'name': n['name'],
                'natIP': None,
                'networkTier': None
            }
        else: #VM with private and public IP
            nic = {
                'network': n['network'].split('/')[-1],
                'subnetwork' : n['subnetwork'].split('/')[-1],
                'networkIP': n['networkIP'],
                'name': n['name'],
                'natIP': n['accessConfigs'][0]['natIP'] if 'natIP' in n['accessConfigs'] else None,
                'networkTier': n['accessConfigs'][0]['networkTier']
            }
        nics.append(nic)

    disks = []
    for i in d['disks']:
        disk = {
            'type': i['type'],
            'mode': i['mode'],
            'source': i['source'] if 'source' in i else None,
            'deviceName': i['deviceName'],
            'index': i['index'],
            'boot': i['boot'],
            'autoDelete': i['autoDelete'],
            'interface': i['interface'],
            'diskSizeGb': int(i['diskSizeGb'])
        }
        disks.append(disk)

    zone = d['zone'].split('/')[-1]
    region = zone[:-2]

    vm_family, vm_cpus, vm_ram_in_gb = get_vm_spec(d['machineType'].split('/')[-1])

    instance = {
        'run_date': run_date,
        'project_id': project_id,
        'vm_id': d['id'],
        'creationTimestamp': d['creationTimestamp'],
        'name': d['name'],
        'description': d['description'] if 'description' in d else None,
        'machineType': d['machineType'].split('/')[-1],
        'vmFamily': vm_family,
        'vmCpus': vm_cpus,
        'vmRamInGb': vm_ram_in_gb,
        'status': d['status'],
        'region': region,
        'zone': zone,
        'networkInterfaces': nics,
        'disks': disks,
        'gpuType': d['guestAccelerators'][0]['acceleratorType'].split('/')[-1] if 'guestAccelerators' in d else None,
        'gpuCount': int(d['guestAccelerators'][0]['acceleratorCount']) if 'guestAccelerators' in d else None,
        'serviceAccounts': d['serviceAccounts'][0]['email'] if 'serviceAccounts' in d else None,
        'onHostMaintenance': d['scheduling']['onHostMaintenance'],
        'automaticRestart': d['scheduling']['automaticRestart'],
        'preemptible': d['scheduling']['preemptible'],
        'cpuPlatform': d['cpuPlatform'],
        'startRestricted': d['startRestricted'],
        'deletionProtection': d['deletionProtection'],
        'lastStartTimestamp': d['lastStartTimestamp'],
        'lastStopTimestamp': d['lastStopTimestamp'] if 'lastStopTimestamp' in d else None
    }

    return instance

# [START list_instances]
def list_instances(project_id):
    instances = []
    cmd = 'gcloud compute instances list --format=json --project={} > /tmp/instance.json'.format(project_id)
    try:
        os.system(cmd)
        instances = load_instances(project_id, '/tmp/instance.json')
        os.remove('/tmp/instance.json')
    except Exception as e:
        print('gcloud command output error: ', e)
    return instances
# [END list_instances]

def load_instances(project_id, result):
    instances = []
    try:
        with open(result, 'r') as fp:
            instance_list = json.load(fp)
        for i in instance_list:
            instances.append(get_instance(project_id, i))
    except Exception as e:
        print('load instance result error: ', e)
    return instances


def check_duplicate(client, run_date):
    sql = 'SELECT COUNT(1) FROM `{}` WHERE run_date="{}"'.format(table_id, run_date)
    query = client.query(sql)
    count = 0
    for row in query:
        count = row[0]
    duplicated = True if count > 0 else False
    return duplicated

def batch(a,n):
    l = len(a)
    for i in range(0,len(a),n):
        yield a[i:min(i+n,l)]