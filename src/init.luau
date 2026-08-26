-- mostly used https://github.com/PaperPrototype/test-octree-planet-terrain-unity as reference
-- to optimize it futher: https://github.com/tunabrain/sparse-voxel-octrees
-- store every node in a svo buffer with pointers to child nodes
-- note: although this can render humonguous amounts of terrain, its still far from optimal

const AssetService = game:GetService("AssetService")
const LogService = game:GetService("LogService")
const RunService = game:GetService("RunService")

const FREQUENCY = 0.001
const AMPLITUDE = 1000
const SEED = 123
const BLOCK_SIZE = 1

const priority = {}

priority.position = Vector3.new(0, 0, 0)

const IndexUtilities = {}

function IndexUtilities.xyzToIndex(x: number, y: number, z: number, width: number, height: number): number
	return z * width * height + y * width + x
end

const Tables = {}

Tables.offsets = {
	[0] = Vector3.new(1, 1, 1),
	Vector3.new(0, 1, 1),
	Vector3.new(0, 1, 0),
	Vector3.new(1, 1, 0),

	Vector3.new(1, 0, 1),
	Vector3.new(0, 0, 1),
	Vector3.new(0, 0, 0),
	Vector3.new(1, 0, 0),
}

Tables.vertices = {
	[0] = Vector3.new(0, 0, 0),
	Vector3.new(1, 0, 0),
	Vector3.new(1, 1, 0),
	Vector3.new(0, 1, 0),
	Vector3.new(0, 0, 1),
	Vector3.new(1, 0, 1),
	Vector3.new(1, 1, 1),
	Vector3.new(0, 1, 1),
}

Tables.normals = {
	[0] = Vector3.xAxis,
	-Vector3.xAxis,
	Vector3.yAxis,
	-Vector3.yAxis,
	Vector3.zAxis,
	-Vector3.zAxis,
}

Tables.buildOrder = {
	[0] = { [0] = 1, 5, 2, 6 },
	{ [0] = 4, 0, 7, 3 },

	{ [0] = 3, 7, 6, 2 },
	{ [0] = 1, 0, 5, 4 },

	{ [0] = 5, 4, 6, 7 },
	{ [0] = 0, 1, 3, 2 },
}

Tables.neighborOffset = {
	[0] = Vector3.xAxis,
	-Vector3.xAxis,
	Vector3.yAxis,
	-Vector3.yAxis,
	Vector3.zAxis,
	-Vector3.zAxis,
}

const JobCompleter = {}
JobCompleter.__index = JobCompleter

type JobCompleter = setmetatable<{
	schedule: () -> (),
	onComplete: () -> (),
}, typeof(JobCompleter)>

function JobCompleter.new(schedule: () -> (), onComplete: () -> ()): JobCompleter
	return setmetatable({
		schedule = schedule,
		onComplete = onComplete,
	}, JobCompleter)
end

const NodeJob = {}
NodeJob.__index = NodeJob

type MeshDataArray = {
	vertices: { Vector3 },
	faces: { { number } },
}

type NodeJob = setmetatable<{
	meshDataArray: MeshDataArray,
	bounds: {},
	planetCenterPosition: Vector3,
	planetRadius: number,

	chunkResolution: number,
	nodeScale: number,
	worldNodePosition: Vector3,

	centerOffset: Vector3,
	normalizedVoxelScale: number,
}, typeof(NodeJob)>

function NodeJob.new(): NodeJob
	return setmetatable({}, NodeJob) :: NodeJob
end

function NodeJob.execute(self: NodeJob)
	--const meshCubeCount = math.ceil(self.chunkResolution ^ 3 / 2)
	--const indiceCount = meshCubeCount * 6 * 6
	--const vertexCount = meshCubeCount * 4 * 6

	const indices = {} -- table.create(indiceCount)
	const vertices = {} -- table.create(vertexCount)
	const normals = {} -- table.create(vertexCount)

	self.centerOffset = Vector3.one * (self.nodeScale / 2)

	self.normalizedVoxelScale = self.nodeScale / self.chunkResolution

	const voxels = buffer.create((self.chunkResolution * 3) ^ 3)
	for x = 0, self.chunkResolution + 2 do
		for y = 0, self.chunkResolution + 2 do
			for z = 0, self.chunkResolution + 2 do
				if not self:isAir(x - 1, y - 1, z - 1) then
					buffer.writeu8(
						voxels,
						IndexUtilities.xyzToIndex(x, y, z, self.chunkResolution + 3, self.chunkResolution + 3),
						1
					)
				end
			end
		end
	end

	local vertexOffset = 4294967297 -- base vid
	-- local indiceOffset = 0

	for x = 0, self.chunkResolution - 1 do
		for y = 0, self.chunkResolution - 1 do
			for z = 0, self.chunkResolution - 1 do
				if self:isAir(x, y, z) then
					continue
				end

				const pos = Vector3.new(x, y, z) * self.normalizedVoxelScale - self.centerOffset
				--const index = Vector3.new(x, y, z)

				for side = 0, 5 do
					if
						not self:isAir(
							x + Tables.neighborOffset[side].X,
							y + Tables.neighborOffset[side].Y,
							z + Tables.neighborOffset[side].Z
						)
					then
						continue
					end

					const vertex1 = Tables.vertices[Tables.buildOrder[side][0]]
					const vertex2 = Tables.vertices[Tables.buildOrder[side][1]]
					const vertex3 = Tables.vertices[Tables.buildOrder[side][2]]
					const vertex4 = Tables.vertices[Tables.buildOrder[side][3]]

					table.insert(vertices, vertex1 * self.normalizedVoxelScale + pos)
					table.insert(vertices, vertex2 * self.normalizedVoxelScale + pos)
					table.insert(vertices, vertex3 * self.normalizedVoxelScale + pos)
					table.insert(vertices, vertex4 * self.normalizedVoxelScale + pos)

					normals[vertexOffset + 0] = Tables.normals[side]
					normals[vertexOffset + 1] = Tables.normals[side]
					normals[vertexOffset + 2] = Tables.normals[side]
					normals[vertexOffset + 3] = Tables.normals[side]

					table.insert(indices, { vertexOffset + 0, vertexOffset + 1, vertexOffset + 2 })
					table.insert(indices, { vertexOffset + 2, vertexOffset + 1, vertexOffset + 3 })

					vertexOffset += 4
				end
			end
		end
	end

	self.meshDataArray.vertices = vertices
	self.meshDataArray.faces = indices
end

function NodeJob.isAir(self: NodeJob, x: number, y: number, z: number): boolean
	const worldVoxelPosition = Vector3.new(x, y, z) * self.normalizedVoxelScale
		+ self.worldNodePosition
		- self.centerOffset
	const worldHeight = math.noise(worldVoxelPosition.X * FREQUENCY, worldVoxelPosition.Z * FREQUENCY, SEED) * AMPLITUDE
	return worldVoxelPosition.Y <= worldHeight
end

const Node = {}
Node.__index = Node

type Node = setmetatable<{
	_isScheduled: boolean,
	_needsDrawn: boolean,

	octree: Octree,
	parent: Node?,
	children: { Node }?,
	divisions: number,
	offset: Vector3,

	mesh: MeshPart?,
}, typeof(Node)>

function Node.new(octree: Octree, parent: Node?, offset: Vector3, divisions: number): Node
	return setmetatable({
		_isScheduled = false,
		_needsDrawn = true,
		octree = octree,
		parent = parent,
		offset = offset,
		divisions = divisions,
	}, Node) :: Node
end

function Node.clear(self: Node)
	if self.mesh then
		self.mesh:Destroy()
		self.mesh = nil
	end
	self._needsDrawn = true
end

function Node.destroy(self: Node)
	if self.mesh then
		self.mesh:Destroy()
		self.mesh = nil
	end
end

function Node.trySchedule(self: Node): JobCompleter?
	if self:isLeaf() and self._needsDrawn and not self._isScheduled then
		const meshDataArray = { vertices = {}, faces = {} }

		const bounds = {}

		const chunkJob = NodeJob.new()
		chunkJob.meshDataArray = meshDataArray
		chunkJob.bounds = bounds
		chunkJob.planetCenterPosition = self.octree.root:nodePosition()
		--chunkJob.planetRadius = self.octree.planetRadius
		chunkJob.chunkResolution = self.octree.chunkResolution
		chunkJob.nodeScale = self:nodeScale()
		chunkJob.worldNodePosition = self:nodePosition()

		self._isScheduled = true
		self._needsDrawn = false

		const jobCompleter = JobCompleter.new(function()
			return chunkJob:execute()
		end, function()
			if #meshDataArray.faces == 0 then
				self._isScheduled = false
				return
			end

			const mesh = assert(AssetService:CreateEditableMesh(), "Failed to create EditableMesh")
			mesh:BatchAdd(Enum.MeshAttribute.Vertex, meshDataArray.vertices)
			mesh:BatchAdd(Enum.MeshAttribute.Face, meshDataArray.faces)

			const result, content = AssetService:CreateDataModelContentAsync(Content.fromObject(mesh))
			mesh:Destroy()
			assert(result == Enum.CreateContentResult.Success, "Failed to create DataModel content")

			const part = AssetService:CreateMeshPartAsync(content, { CollisionFidelity = Enum.CollisionFidelity.Box })
			part.Anchored = true
			part.CanCollide = false
			part.Color = Color3.new(1, 1, 1)
			part.Parent = workspace

			const nodePosition = self:nodePosition()
			part.Position = nodePosition
			part.Name = tostring(nodePosition)

			self.mesh = part
			self._isScheduled = false
		end)

		return jobCompleter
	end

	return nil
end

function Node.isLeaf(self: Node): boolean
	return not self.children
end

function Node.nodeResolution(self: Node): number
	return 2 ^ (self.divisions - 1)
end

function Node.nodeScale(self: Node): number
	return self.octree.chunkResolution * self:nodeResolution() * BLOCK_SIZE
end

function Node.nodePosition(self: Node): Vector3
	if not self.parent then
		return self.offset
	end

	const nodeScale = self:nodeScale()

	return (self.offset * nodeScale) - (Vector3.one * (nodeScale / 2)) + self.parent:nodePosition()
end

const Octree = {}

function Octree.start(self: Octree)
	self._nodeResolution = 2 ^ (self.divisions - 1)
	self._nodeScale = self.chunkResolution * self._nodeResolution

	--const offset = Vector3.yAxis
	--const pos = (offset * self._nodeScale) - (Vector3.one * (self._nodeScale / 2))
	self.root = Node.new(self, nil, Vector3.zero, self.divisions)

	LogService:Info("nodeResolution: {nodeResolution}", { nodeResolution = self._nodeResolution })
	LogService:Info("nodeScale: {nodeScale}", { nodeScale = self._nodeScale })

	self._worldVoxelsCount = (self._nodeResolution ^ 3) * (self.chunkResolution ^ 3)
	LogService:Info("world voxels count: {worldVoxelsCount}", { worldVoxelsCount = self._worldVoxelsCount })

	self.startTime = os.clock()
end

function Octree.update(self: Octree)
	priority.position = workspace.testPlayer.Position
	self:traverse(self.root, 0)
	self:schedule(self.root)
end

function Octree.lateUpdate(self: Octree)
	if #self.toComplete > 0 then
		const w = os.clock()

		repeat
			const job = table.remove(self.toComplete)
			if not job then
				if self.startTime then
					-- note: this never runs (needs fixing)
					const elapsed = os.clock() - self.startTime
					LogService:Info("meshing took: {elapsed}s", { elapsed = elapsed })
					self.startTime = nil
				end
				return
			end

			job.schedule()
			job.onComplete()
		until os.clock() - w > 0.008
	end
end

function Octree.traverse(self: Octree, node: Node, creations: number)
	if creations > self.maxNodeCreationsPerFrame then
		return
	end

	local createdNewNodes = false

	if node.divisions > 1 then
		if self:shouldSubdivide(node) then
			node:clear()

			if not node.children then
				createdNewNodes = true

				const children = {}
				for i = 0, 7 do
					children[i] = Node.new(self, node, Tables.offsets[i], node.divisions - 1)
				end
				node.children = children
			end
		else
			self:deleteChildren(node)
		end

		if createdNewNodes then
			creations += 1
		end

		if node.children then
			for i = 0, 7 do
				self:traverse(node.children[i], creations)
			end
		end
	end
end

function Octree.shouldSubdivide(self: Octree, node: Node): boolean
	const center = node:nodePosition()
	const scale = (node:nodeScale() * self.innerRadiusPadding + 1) * Vector3.one

	const minBound = center - scale
	const maxBound = center + scale

	const insideX = priority.position.X >= minBound.X and priority.position.X <= maxBound.X
	const insideY = priority.position.Y >= minBound.Y and priority.position.Y <= maxBound.Y
	const insideZ = priority.position.Z >= minBound.Z and priority.position.Z <= maxBound.Z

	return insideX and insideY and insideZ
end

function Octree.schedule(self: Octree, node: Node)
	const completer = node:trySchedule()
	if completer then
		table.insert(self.toComplete, completer)
	end

	if not node.children then
		return
	end

	for i = 0, 7 do
		self:schedule(node.children[i])
	end
end

function Octree.deleteChildren(self: Octree, node: Node)
	if not node.children then
		return
	end

	for i = 0, 7 do
		self:deleteChildren(node.children[i])
	end

	for i = 0, 7 do
		node.children[i]:destroy()
	end
	node.children = nil
end

type Octree = typeof(Octree) & {
	maxNodeCreationsPerFrame: number,

	chunkResolution: number,

	innerRadiusPadding: number,
	divisions: number,

	root: Node,
	_nodeResolution: number,
	_nodeScale: number,
	_worldVoxelsCount: number,
	toComplete: { JobCompleter },

	startTime: number?,
}

const octree = Octree :: Octree

octree.maxNodeCreationsPerFrame = 60

octree.chunkResolution = 16

octree.innerRadiusPadding = 2
octree.divisions = 11

octree.toComplete = {}

octree:start()

RunService.Heartbeat:Connect(function()
	octree:update()
	octree:lateUpdate()
end)
