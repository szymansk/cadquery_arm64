import cadquery as cq
from cadq_server_connector import CQServerConnector

connector = CQServerConnector("http://cq-server:5000/json")

model = cq.Workplane().box(1, 1, 1)

connector.render("test_model", model)