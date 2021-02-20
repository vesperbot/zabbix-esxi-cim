#!/usr/bin/env python3
from __future__ import print_function
import sys
import pywbem
import json
import argparse
import shlex

#debug print function from here https://stackoverflow.com/a/14981125/1627055
def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)

#debugfile=open('/tmp/pywbem-zabbix-wrapper.txt','a')
#print(sys.argv,file=debugfile)
# In order to avoid extensive debugging with Zabbix passing parameters to your script, NEVER EVER use single quotes in Zabbix keys!
# Double quotes are OK, but single quotes get wrapped in double quotes at the time of passing parameters to script, causing mayhem in args parsing
parser=argparse.ArgumentParser(description='Retrieve information from a CIM/WBEM server.',\
epilog="Example:\n    %(prog)s -s server.example.com -c 'CIM_ComputerSystem' -i 'SystemID=\"foo\"'\nOr:\n    %(prog)s -s server.example.com -c 'CIM_ComputerSystem' -i '{\"SystemID\": \"foo\"}'",\
formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('-s','--server','--host',help='Server to connect to',dest='target',required=True)
parser.add_argument('-u','--username',help='User name to connect (if required)')
# user/pass sometimes might be not required. We do, but still
parser.add_argument('-p','--password',help='Password to use for connection (if required)')
parser.add_argument('-P','--port',help='Port to connect to CIM/WBEM server. Defaults to 5988 for http, 5989 for https scheme.')
parser.add_argument('-n','--namespace',help='CIM namespace to run queries',default='root/cimv2')
parser.add_argument('-c','--class',help='CIM class to retrieve. If omitted, enumerate classes is performed',dest='cimclass')
parser.add_argument('--zabbix',help='Enumerate instances of class or classes in namespace. Produces JSON output for Zabbix',action='store_true')
parser.add_argument('-i','--item',help='Item to retrieve info. If omitted, and no "--zabbix" flag is specified, produces raw output of instance enumeration.\nExpected an old format string of "name=value,name=value" format, or a JSON string encoding properties to filter.')
parser.add_argument('--http',help='Use http to connect, default is https.',action='store_true')
parser.add_argument('--debug',help='Gather debug output in stderr. Best used while developing scripts or testing.',action='store_true')
args=parser.parse_args()
eprint(vars(args)) if args.debug else None

itempresent=(args.item is not None)
classpresent=(args.cimclass is not None)
if (itempresent and (not classpresent)):
  print('You need to provide a class name in order to retrieve an item!')
  parser.print_help()
  sys.exit(1)

if (itempresent):
  try:
    keybindings=json.loads(args.item)
  except:
    # not a JSON, let's try parsing as string
    # if this will not split correctly, there will just be no valid item.
    keybindings={}
    kvp=shlex.split(args.item,'.')
    for kv in kvp:
      tuple=shlex.split(kv,'=')
      keybindings[tuple[0]]=tuple[1]
  eprint('Item path parsed as:',json.dumps(keybindings)) if args.debug else None

wurl = 'http://' if args.http else 'https://'
wurl = wurl+args.target
if (args.port is None):
  wurl=wurl+(':5988' if args.http else ':5989')
else:
  wurl = wurl + ':'+args.port

eprint('Connection URL:',wurl) if args.debug else None # interesting but this really works
creds=(args.username, args.password) if (args.username is not None) else None
connection=pywbem.WBEMConnection(wurl,creds,no_verification=True,default_namespace=args.namespace,use_pull_operations=None)
# None for pull ops lets server decide if this is ever possible, setting True would crash if not, setting False is default and failsafe
try:
  if not classpresent:
    # making ECN call
    data=connection.EnumerateClassNames(args.namespace,None,True)
  elif not itempresent:
    data=connection.EnumerateInstanceNames(args.cimclass,args.namespace)
  else:
    path=pywbem.CIMInstanceName(classname=args.cimclass,keybindings=keybindings)
    # we have already parsed item string if it was present
    data=connection.GetInstance(path)
except pywbem.CIMError as exc:
  print('Exception while connecting:',exc.status_code_name)
  print(exc.status_description)
  sys.exit(1)

if isinstance(data, list):
  # data is a list - can iterate through
  dicts=[]
  for element in data:
    od={}
    if isinstance(element,pywbem.CIMInstanceName):
      # instance names have class name and keybindings
      od['classname']=element.classname
      od['keybindings']=dict(element.keybindings)
      # keybindings are a dict, so JSON-able, but CIN itself is not
      # ha ha, NOT! let's try converting to "dict" - this works
    elif isinstance(element,pywbem.CIMInstance):
      for tuples in element.items():
        od[tuples[0]]=tuples[1]
    else:
      # hm what else can be in a list of names? A string
      od=element
    dicts.append(od) # proper way of creating a list
elif isinstance(data,pywbem.CIMInstance):
  # single element, likely a CIMInstance
  od={}
  for tuples in data.items():
    od[tuples[0]]=tuples[1]
  dicts=[od] # uniform output in "dicts". Can post-process instance data in Zabbix
else:
  eprint('A single element of unknown type is returned:',type(data)) if args.debug else None
  # don't exit, as of now
  dicts=[data]

if (args.zabbix):
  zbx={'data':[]} # hum, works this way
  for od in dicts:
    elem={}
    if isinstance(od, dict):
      # a dictionary. If classname is present, a path aka CIN, if not, an instance
      eprint('Received a dict:\n',json.dumps(od)) if args.debug else None
      # at this point all data is serializable
      if od['classname'] is not None:
        elem['{#CLASSNAME}']=od['classname']
        kb=od['keybindings']
        # strip unneeded info aka class names from keybindings
        itemnames=[]
        for k,v in list(kb.items()):
          if 'Class' in k:
            del kb[k]
          else:
            itemnames.append(v) # collect all names of instances, including its own
            # never forget, adding to an array is done with .append() or else
        elem['{#CLASSPATH}']=json.dumps(kb)
        # elem['{#CLASSPATH}']=kb # dual escaping does bad when importing a JSON unescapes only once
        # BUT Zabbix requires a string in place of a LLD macro, so returning to try dump again and would try resolving it somehow
        # strangely need not do an extra resolve step, classpath is passed unescaped from Zabbix
        elem['{#INSTANCENAME}']='_'.join(itemnames) # ohhh, putting a cart before a horse
      else:
        # an instance. Instances are just dumped
        elem['{#ITEM}']=od
        # either this, or plain elem=od. After all I expect get-items to be run without "--zabbix" flag
    else:
      # a string. For Zabbix, need to provide a name. Could do as above
      elem['{#ITEM}']=od
    zbx['data'].append(elem) # collect
  print(json.dumps(zbx))
else:
  print(json.dumps(dicts))
