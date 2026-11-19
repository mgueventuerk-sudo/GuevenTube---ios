import plistlib, uuid, sys
def u(): return str(uuid.uuid4()).upper()
def wait(sec):
    return {"WFWorkflowActionIdentifier": "is.workflow.actions.delay",
            "WFWorkflowActionParameters": {"WFDelayTime": sec, "UUID": u()}}
def vpn(mode):
    return {"WFWorkflowActionIdentifier": "is.workflow.actions.vpn.set",
            "WFWorkflowActionParameters": {"WFVPNActionParameter": mode, "UUID": u()}}
refresh = {"WFWorkflowActionIdentifier": "com.SideStore.SideStore.RefreshAllIntent",
           "WFWorkflowActionParameters": {"ShowWhenRun": False, "UUID": u()}}
actions = [vpn("connect"), wait(7), refresh, wait(30), vpn("disconnect")]
wf = {
  "WFWorkflowClientVersion": "2900", "WFWorkflowClientRelease": "18.0", "WFWorkflowMinimumClientVersion": 900,
  "WFWorkflowMinimumClientVersionString": "900", "WFWorkflowIcon": {"WFWorkflowIconStartColor": 463140863, "WFWorkflowIconGlyphNumber": 59511},
  "WFWorkflowImportQuestions": [], "WFWorkflowTypes": [], "WFWorkflowInputContentItemClasses": [],
  "WFWorkflowActions": actions,
}
with open(sys.argv[1], "wb") as f: plistlib.dump(wf, f, fmt=plistlib.FMT_BINARY)
