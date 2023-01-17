import json
import sys

import requests
from jupyter_cadquery.base import _tessellate_group
from jupyter_cadquery.cad_objects import to_assembly
from jupyter_cadquery.utils import numpy_to_json


def get_json_model(assembly_children) -> list:
    """Return the tesselated model of the assembly,
    as a dictionnary usable by three-cad-viewer."""

    try:
        jcq_assembly = to_assembly(assembly_children)
        assembly_tesselated = _tessellate_group(jcq_assembly)
        assembly_json = numpy_to_json(assembly_tesselated)
    except Exception as error:
        raise CQServerConnectorError('An error occured when tesselating the assembly.') from error

    return json.loads(assembly_json)


def get_data(module_name, json_model) -> dict:
    """Return the data to send to the client, that includes the tesselated model."""

    data = {}

    try:
        data = {
            'module_name': module_name,
            'model': json_model,
            'source': ''
        }
    except CQServerConnectorError as error:
        raise (error)

    return data


class CQServerConnector:

    def __init__(self, url):
        self.url = url

    def render(self, name, cq_model):
        json_model = get_json_model(cq_model)
        json_data = get_data(name, json_model)
        self.post_data(json_data)

    def post_data(self, data):
        # sending post request and saving response as response object
        r = requests.post(url=self.url, json=data, timeout=20)
        # extracting response text 
        resp = r.text
        print(f"Render Response:{resp}")
        return r


class CQServerConnectorError(Exception):
    """Error class used to define ModuleManager errors."""

    def __init__(self, message: str, stacktrace: str = ''):
        self.message = message
        self.stacktrace = stacktrace

        print('Module manager error: ' + message, file=sys.stderr)
        if stacktrace:
            print(stacktrace, file=sys.stderr)

        super().__init__(self.message)
