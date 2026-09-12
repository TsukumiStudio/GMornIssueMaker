extends RefCounted

## MornIssueBridgeのURLとIssue作成先です。
var endpoint := ""
var repository := ""

func load_from_project() -> void:
	endpoint = String(ProjectSettings.get_setting("gmorn_issue_maker/endpoint", ""))
	repository = String(ProjectSettings.get_setting("gmorn_issue_maker/repository", ""))
