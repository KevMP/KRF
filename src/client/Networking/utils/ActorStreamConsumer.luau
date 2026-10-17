--!strict
local Types = require(script.Parent.Parent.types)

-- N5 installs its private consumer before Client.Init. N4 never queues decoded history.
local ActorStreamConsumer = {}
local installed: Types.ActorStreamConsumer? = nil
function ActorStreamConsumer.Install(consumer: Types.ActorStreamConsumer?): ()
	installed = consumer
end
function ActorStreamConsumer.Get(): Types.ActorStreamConsumer?
	return installed
end
return ActorStreamConsumer
