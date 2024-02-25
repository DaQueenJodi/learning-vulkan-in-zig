const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const c = @import("c.zig");

const WIDTH = 800;
const HEIGHT = 600;

const enable_validation_layers = builtin.mode == .Debug;
const enable_debug_extension = builtin.mode == .Debug;
const VALIDATION_LAYERS = [_][*:0]const u8{
    "VK_LAYER_KHRONOS_validation",
};
const DEBUG_EXTENSIONS = [_][*:0]const u8{
    c.VK_EXT_DEBUG_UTILS_EXTENSION_NAME,
};
const DEVICE_EXTENSIONS = [_][*:0]const u8{
    c.VK_KHR_SWAPCHAIN_EXTENSION_NAME,
    c.VK_KHR_DYNAMIC_RENDERING_EXTENSION_NAME,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try App.init(allocator);
    defer app.deinit(allocator);

    while (c.glfwWindowShouldClose(app.window) == 0) {
        c.glfwPollEvents();
    }
}

fn initWindow(w: c_int, h: c_int, name: [*:0]const u8) !*c.GLFWwindow {
    if (c.glfwInit() == c.GLFW_FALSE) return error.FailedToInitGlfw;
    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
    c.glfwWindowHint(c.GLFW_RESIZABLE, c.GLFW_FALSE);
    return c.glfwCreateWindow(w, h, name, null, null) orelse {
        return error.FailedToCreateGlfwWindow;
    };
}
fn createInstance(allocator: Allocator) !c.VkInstance {
    if (enable_validation_layers and !try areValidationLayersSupported(allocator)) {
        return error.ValidationLayersUnsupported;
    }
    const app_info = c.VkApplicationInfo{
        .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "Hello Triangle",
        .applicationVersion = c.VK_MAKE_VERSION(1, 0, 0),
        .pEngineName = "No Engine",
        .engineVersion = c.VK_MAKE_VERSION(1, 0, 0),
        .apiVersion = c.VK_API_VERSION_1_3,
    };
    var glfw_extension_count: u32 = undefined;
    const glfw_extensions = c.glfwGetRequiredInstanceExtensions(&glfw_extension_count);
    if (glfw_extension_count == 0) return error.FailedToGetRequiredGlfwExtensions;
    var extensions = std.ArrayList([*c]const u8).init(allocator);
    defer extensions.deinit();
    try extensions.appendSlice(glfw_extensions[0..glfw_extension_count]);
    if (enable_debug_extension) {
        try extensions.appendSlice(&DEBUG_EXTENSIONS);
    }
    const create_info = c.VkInstanceCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app_info,
        .enabledExtensionCount = @intCast(extensions.items.len),
        .ppEnabledExtensionNames = extensions.items.ptr,
        .enabledLayerCount = if (enable_validation_layers) VALIDATION_LAYERS.len else 0,
        .ppEnabledLayerNames = if (enable_validation_layers) &VALIDATION_LAYERS else null,
    };

    var instance: c.VkInstance = undefined;
    if (c.vkCreateInstance(
        &create_info,
        null,
        &instance,
    ) != c.VK_SUCCESS) return error.FailedToCreateInstance;
    return instance;
}

const App = struct {
    window: *c.GLFWwindow,
    instance: c.VkInstance,
    physical_device: c.VkPhysicalDevice,
    logical_device: c.VkDevice,
    graphics_queue: c.VkQueue,
    surface: c.VkSurfaceKHR,
    swapchain: c.VkSwapchainKHR,
    swap_images: []c.VkImage,
    swap_image_views: []c.VkImageView,
    swapchain_info: SwapChainInfo,
    pipeline_layout: c.VkPipelineLayout,
    pipeline: c.VkPipeline,
    debug_messenger: if (enable_debug_extension) c.VkDebugUtilsMessengerEXT else void,
    pub fn init(allocator: Allocator) !App {
        // glfw needs to be initialized before the instance is created
        const window = try initWindow(WIDTH, HEIGHT, "welp");
        const instance = try createInstance(allocator);
        const surface = try createSurface(instance, window);
        const physical_device = try pickPhysicalDevice(allocator, instance, surface);
        const device_creation_result = try createLogicalDevice(allocator, physical_device, surface);
        const logical_device = device_creation_result.device;
        const swapchain_creation_result = try createSwapchain(
            allocator,
            instance,
            physical_device,
            logical_device,
            surface,
            window,
        );
        const swapchain = swapchain_creation_result.swapchain;
        const extent = swapchain_creation_result.extent;
        const swap_images = try getSwapchainImages(allocator, logical_device, swapchain);
        errdefer allocator.free(swap_images);
        const image_format = swapchain_creation_result.image_format;

        const vert_module = try createShaderModule(
            allocator,
            logical_device,
            "shaders/spv/triangle_vert.spv",
        );
        defer c.vkDestroyShaderModule(logical_device, vert_module, null);
        const frag_module = try createShaderModule(
            allocator,
            logical_device,
            "shaders/spv/triangle_frag.spv",
        );
        defer c.vkDestroyShaderModule(logical_device, frag_module, null);

        const graphics_pipeline_creation_result = try createGraphicsPipeline(
            logical_device,
            extent,
            vert_module,
            frag_module,
        );
        return App{
            .instance = instance,
            .window = window,
            .physical_device = physical_device,
            .logical_device = logical_device,
            .graphics_queue = device_creation_result.graphics_queue,
            .surface = surface,
            .swapchain = swapchain,
            .debug_messenger = if (enable_debug_extension) try setupDebugger(instance) else {},
            .swap_images = swap_images,
            .swap_image_views = try createImageViews(
                allocator,
                logical_device,
                swap_images,
                image_format,
            ),
            .swapchain_info = .{
                .image_format = image_format,
                .extent = extent,
            },
            .pipeline = graphics_pipeline_creation_result.pipeline,
            .pipeline_layout = graphics_pipeline_creation_result.layout,
        };
    }
    pub fn deinit(self: App, allocator: Allocator) void {
        c.vkDestroyPipeline(self.logical_device, self.pipeline, null);
        c.vkDestroyPipelineLayout(self.logical_device, self.pipeline_layout, null);
        for (self.swap_image_views) |image_view| {
            c.vkDestroyImageView(self.logical_device, image_view, null);
        }
        allocator.free(self.swap_image_views);
        allocator.free(self.swap_images);
        c.vkDestroySwapchainKHR(self.logical_device, self.swapchain, null);
        c.vkDestroyDevice(self.logical_device, null);
        c.vkDestroySurfaceKHR(self.instance, self.surface, null);
        if (enable_debug_extension)
            _ = destroyDebugMessengerEXT(self.instance, self.debug_messenger);
        c.vkDestroyInstance(self.instance, null);
        c.glfwDestroyWindow(self.window);
        c.glfwTerminate();
    }
};

fn areValidationLayersSupported(allocator: Allocator) !bool {
    var layer_count: u32 = undefined;
    if (c.vkEnumerateInstanceLayerProperties(
        &layer_count,
        null,
    ) != c.VK_SUCCESS) {
        return error.UnabledToEnumerateInstanceLayerProperties;
    }

    const available_layers = try allocator.alloc(c.VkLayerProperties, layer_count);
    defer allocator.free(available_layers);

    if (c.vkEnumerateInstanceLayerProperties(
        &layer_count,
        available_layers.ptr,
    ) != c.VK_SUCCESS) {
        return error.UnabledToEnumerateInstanceLayerProperties;
    }

    for (VALIDATION_LAYERS) |expected_layer_name| {
        var found = false;
        for (available_layers) |actual_layer_properties| {
            if (std.mem.orderZ(
                u8,
                expected_layer_name,
                @ptrCast(&actual_layer_properties.layerName),
            ) == .eq) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn debugCallback(
    severity: c.VkDebugUtilsMessageSeverityFlagBitsEXT,
    _: c.VkDebugUtilsMessageTypeFlagsEXT,
    callback_data_maybe: ?*const c.VkDebugUtilsMessengerCallbackDataEXT,
    _: ?*anyopaque,
) callconv(.C) c.VkBool32 {
    // only NULL if the type is
    // 'VK_DEBUG_UTILS_MESSAGE_TYPE_DEVICE_ADDRESS_BINDING_BIT_EXT'
    // which we don't get
    const callback_data = callback_data_maybe.?;
    switch (severity) {
        c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT => {
            std.log.debug("{s}", .{callback_data.pMessage});
        },
        c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT => {
            std.log.info("{s}", .{callback_data.pMessage});
        },
        c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT => {
            std.log.warn("{s}", .{callback_data.pMessage});
        },
        c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT => {
            std.log.err("{s}", .{callback_data.pMessage});
        },
        else => unreachable,
    }
    return c.VK_FALSE;
}

fn createDebugMessengerEXT(
    instance: c.VkInstance,
    create_info: *const c.VkDebugUtilsMessengerCreateInfoEXT,
    debug_messenger: *c.VkDebugUtilsMessengerEXT,
) c.VkResult {
    const func_maybe: c.PFN_vkCreateDebugUtilsMessengerEXT =
        @ptrCast(c.vkGetInstanceProcAddr(instance, "vkCreateDebugUtilsMessengerEXT"));
    const func = func_maybe orelse return c.VK_ERROR_EXTENSION_NOT_PRESENT;
    return func(instance, create_info, null, debug_messenger);
}

fn destroyDebugMessengerEXT(
    instance: c.VkInstance,
    debug_messenger: c.VkDebugUtilsMessengerEXT,
) void {
    const func_maybe: c.PFN_vkDestroyDebugUtilsMessengerEXT =
        @ptrCast(c.vkGetInstanceProcAddr(instance, "vkDestroyDebugUtilsMessengerEXT"));
    // only called if debug messenger was created,
    // and if that succeeded this function has to exist
    const func = func_maybe orelse unreachable;
    func(instance, debug_messenger, null);
}
fn setupDebugger(instance: c.VkInstance) !c.VkDebugUtilsMessengerEXT {
    const create_info = c.VkDebugUtilsMessengerCreateInfoEXT{
        .sType = c.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
        .messageSeverity = c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT |
            c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT |
            c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
            c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
        .messageType = c.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
            c.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
            c.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
            c.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT |
            c.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT,
        .pfnUserCallback = debugCallback,
    };

    var debug_messenger: c.VkDebugUtilsMessengerEXT = undefined;
    if (createDebugMessengerEXT(
        instance,
        &create_info,
        &debug_messenger,
    ) != c.VK_SUCCESS) {
        return error.FailedToCreateDebugMessenger;
    }
    return debug_messenger;
}

fn pickPhysicalDevice(
    allocator: Allocator,
    instance: c.VkInstance,
    surface: c.VkSurfaceKHR,
) !c.VkPhysicalDevice {
    var device_count: u32 = undefined;
    if (c.vkEnumeratePhysicalDevices(instance, &device_count, null) != c.VK_SUCCESS) {
        return error.FailedToEnumeratePhysicalDevices;
    }
    if (device_count == 0) {
        return error.NoGpusWithVulkanFound;
    }
    const devices = try allocator.alloc(c.VkPhysicalDevice, device_count);
    defer allocator.free(devices);
    if (c.vkEnumeratePhysicalDevices(instance, &device_count, devices.ptr) != c.VK_SUCCESS) {
        return error.FailedToEnumeratePhysicalDevices;
    }

    for (devices) |device| {
        if (try isPhysicalDeviceSuitable(allocator, instance, device, surface)) return device;
    }
    return error.NoSuitableGPUsFound;
}
fn isPhysicalDeviceSuitable(
    allocator: Allocator,
    instance: c.VkInstance,
    device: c.VkPhysicalDevice,
    surface: c.VkSurfaceKHR,
) !bool {
    _ = findQueueFamilies(allocator, device, surface) catch |e| {
        switch (e) {
            error.SuitableQueueNotFound => return false,
            else => return e,
        }
    };
    if (!try doesPhysicalDeviceSupportExtensions(allocator, device)) return false;
    _ = getSwapchainCapabilities(
        allocator,
        instance,
        device,
        surface,
    ) catch |e| {
        switch (e) {
            error.NoFormat, error.NoPresentMode => return false,
            else => return e,
        }
    };
    return true;
}
fn doesPhysicalDeviceSupportExtensions(allocator: Allocator, device: c.VkPhysicalDevice) !bool {
    var extension_count: u32 = undefined;
    if (c.vkEnumerateDeviceExtensionProperties(
        device,
        null,
        &extension_count,
        null,
    ) != c.VK_SUCCESS) {
        return error.FailedToEnumerateDeviceExtensions;
    }
    const extensions = try allocator.alloc(c.VkExtensionProperties, extension_count);
    defer allocator.free(extensions);
    if (c.vkEnumerateDeviceExtensionProperties(
        device,
        null,
        &extension_count,
        extensions.ptr,
    ) != c.VK_SUCCESS) {
        return error.FailedToEnumerateDeviceExtensions;
    }

    var required_extensions =
        std.BoundedArray([*:0]const u8, DEVICE_EXTENSIONS.len).fromSlice(&DEVICE_EXTENSIONS) catch unreachable;
    while (required_extensions.len > 0) {
        const required_extension = required_extensions.pop();
        var found = false;
        for (extensions) |extension| {
            if (std.mem.orderZ(
                u8,
                @ptrCast(&extension.extensionName),
                required_extension,
            ) == .eq) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

const QueueFamilyIndices = struct {
    graphics: u32,
    present: u32,
};

fn findQueueFamilies(allocator: Allocator, device: c.VkPhysicalDevice, surface: c.VkSurfaceKHR) !QueueFamilyIndices {
    var queue_family_count: u32 = undefined;
    c.vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, null);
    const queue_families = try allocator.alloc(c.VkQueueFamilyProperties, queue_family_count);
    defer allocator.free(queue_families);
    c.vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, queue_families.ptr);
    return .{
        .graphics = blk: {
            for (queue_families, 0..) |q, i| {
                if (q.queueFlags & c.VK_QUEUE_GRAPHICS_BIT > 0) break :blk @intCast(i);
            }
            return error.SuitableQueueNotFound;
        },
        .present = blk: {
            for (queue_families, 0..) |_, i| {
                var present_support: c.VkBool32 = undefined;
                if (c.vkGetPhysicalDeviceSurfaceSupportKHR(
                    device,
                    @intCast(i),
                    surface,
                    &present_support,
                ) != c.VK_SUCCESS) return error.FailedToGetPresentSupport;
                if (present_support == 1) break :blk @intCast(i);
            }
            return error.SuitableQueueNotFound;
        },
    };
}

const DeviceCreationResult = struct {
    device: c.VkDevice,
    graphics_queue: c.VkQueue,
    present_queue: c.VkQueue,
};
fn createLogicalDevice(
    allocator: Allocator,
    physical_device: c.VkPhysicalDevice,
    surface: c.VkSurfaceKHR,
) !DeviceCreationResult {
    const indices = try findQueueFamilies(allocator, physical_device, surface);

    const indices_fields = std.meta.fields(QueueFamilyIndices);
    const all_indices_values: [indices_fields.len]u32 = blk: {
        var all_indices_values = std.BoundedArray(u32, indices_fields.len){};
        inline for (indices_fields) |field| {
            assert(field.type == u32);
            all_indices_values.append(@field(indices, field.name)) catch unreachable;
        }
        assert(all_indices_values.len == indices_fields.len);
        break :blk all_indices_values.buffer;
    };
    var unique_indices_values = std.BoundedArray(u32, indices_fields.len){};
    for (all_indices_values) |v| {
        if (std.mem.indexOfScalar(u32, unique_indices_values.slice(), v) == null) {
            unique_indices_values.append(v) catch unreachable;
        }
    }
    var queue_create_infos = std.BoundedArray(
        c.VkDeviceQueueCreateInfo,
        indices_fields.len,
    ){};

    for (unique_indices_values.slice()) |queue_index| {
        queue_create_infos.append(.{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .queueFamilyIndex = queue_index,
            .queueCount = 1,
            .pQueuePriorities = &[1]f32{1.0},
        }) catch unreachable;
    }

    const dynamic_rendering_feature = c.VkPhysicalDeviceDynamicRenderingFeaturesKHR{
        .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES_KHR,
        .dynamicRendering = c.VK_TRUE,
    };
    const device_features = c.VkPhysicalDeviceFeatures{};
    const create_info = c.VkDeviceCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = &dynamic_rendering_feature,
        .queueCreateInfoCount = queue_create_infos.len,
        .pQueueCreateInfos = queue_create_infos.slice().ptr,
        .pEnabledFeatures = &device_features,
        .enabledLayerCount = if (enable_validation_layers) VALIDATION_LAYERS.len else 0,
        .ppEnabledLayerNames = if (enable_validation_layers) &VALIDATION_LAYERS else null,
        .enabledExtensionCount = DEVICE_EXTENSIONS.len,
        .ppEnabledExtensionNames = &DEVICE_EXTENSIONS,
    };
    var device: c.VkDevice = undefined;
    if (c.vkCreateDevice(physical_device, &create_info, null, &device) != c.VK_SUCCESS) {
        return error.FailedToCreateLogicalDevice;
    }

    var graphics_queue: c.VkQueue = undefined;
    c.vkGetDeviceQueue(device, indices.graphics, 0, &graphics_queue);
    var present_queue: c.VkQueue = undefined;
    c.vkGetDeviceQueue(device, indices.present, 0, &present_queue);

    return .{
        .device = device,
        .graphics_queue = graphics_queue,
        .present_queue = present_queue,
    };
}

fn createSurface(instance: c.VkInstance, window: *c.GLFWwindow) !c.VkSurfaceKHR {
    var surface: c.VkSurfaceKHR = undefined;
    if (c.glfwCreateWindowSurface(instance, window, null, &surface) != c.VK_SUCCESS) {
        return error.FailedToCreateSurface;
    }
    return surface;
}

const SwapchainCapabilities = struct {
    capabilities: c.VkSurfaceCapabilitiesKHR,
    format: c.VkSurfaceFormatKHR,
    present_mode: c.VkPresentModeKHR,
};

fn getSwapchainCapabilities(
    allocator: Allocator,
    instance: c.VkInstance,
    device: c.VkPhysicalDevice,
    surface: c.VkSurfaceKHR,
) !SwapchainCapabilities {
    var capabilities: c.VkSurfaceCapabilitiesKHR = undefined;
    if (getPhysicalDeviceSurfaceCapabilitiesKHR(
        instance,
        device,
        surface,
        &capabilities,
    ) != c.VK_SUCCESS) {
        return error.FailedToGetSurfaceCapabilities;
    }

    var format_count: u32 = undefined;
    if (c.vkGetPhysicalDeviceSurfaceFormatsKHR(
        device,
        surface,
        &format_count,
        null,
    ) != c.VK_SUCCESS) {
        return error.FailedToGetPhysicalDeviceSurfaceFormats;
    }
    if (format_count == 0) return error.NoFormat;
    const formats = try allocator.alloc(c.VkSurfaceFormatKHR, format_count);
    defer allocator.free(formats);
    if (c.vkGetPhysicalDeviceSurfaceFormatsKHR(
        device,
        surface,
        &format_count,
        formats.ptr,
    ) != c.VK_SUCCESS) {
        return error.FailedToGetPhysicalDeviceSurfaceFormats;
    }

    var present_mode_count: u32 = undefined;
    if (present_mode_count == 0) return error.NoPresentMode;
    if (c.vkGetPhysicalDeviceSurfacePresentModesKHR(
        device,
        surface,
        &present_mode_count,
        null,
    ) != c.VK_SUCCESS) {
        return error.FailedToGetPhysicalDeviceSurfacePresentModes;
    }
    const present_modes = try allocator.alloc(c.VkPresentModeKHR, present_mode_count);
    defer allocator.free(present_modes);
    if (c.vkGetPhysicalDeviceSurfacePresentModesKHR(
        device,
        surface,
        &present_mode_count,
        present_modes.ptr,
    ) != c.VK_SUCCESS) {
        return error.FailedToGetPhysicalDeviceSurfacePresentModes;
    }

    return .{
        .capabilities = capabilities,
        .format = chooseFormat(formats),
        .present_mode = choosePresentMode(present_modes),
    };
}

fn chooseFormat(formats: []const c.VkSurfaceFormatKHR) c.VkSurfaceFormatKHR {
    for (formats) |format| {
        if (format.format == c.VK_FORMAT_B8G8R8A8_SRGB and
            format.colorSpace == c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)
        {
            return format;
        }
    }
    return formats[0];
}
fn choosePresentMode(present_modes: []const c.VkPresentModeKHR) c.VkPresentModeKHR {
    for (present_modes) |present_mode| {
        if (present_mode == c.VK_PRESENT_MODE_MAILBOX_KHR) return present_mode;
    }
    // gaurenteed to exist on all devices
    return c.VK_PRESENT_MODE_FIFO_KHR;
}

fn chooseSwapExtent(window: *c.GLFWwindow, capabilities: c.VkSurfaceCapabilitiesKHR) c.VkExtent2D {
    if (capabilities.currentExtent.width != std.math.maxInt(u32)) {
        return capabilities.currentExtent;
    }
    var width: c_int = undefined;
    var height: c_int = undefined;
    c.glfwGetFramebufferSize(window, &width, &height);
    const width_u: u32 = @intCast(width);
    const height_u: u32 = @intCast(height);
    return .{
        .width = @min(width_u, capabilities.maxImageExtent.width),
        .height = @min(height_u, capabilities.maxImageExtent.height),
    };
}

fn getPhysicalDeviceSurfaceCapabilitiesKHR(
    instance: c.VkInstance,
    device: c.VkPhysicalDevice,
    surface: c.VkSurfaceKHR,
    capabilities: *c.VkSurfaceCapabilitiesKHR,
) c.VkResult {
    const func_maybe: c.PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR =
        @ptrCast(c.vkGetInstanceProcAddr(instance, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR"));
    // only called if debug messenger was created,
    // and if that succeeded this function has to exist
    const func = func_maybe orelse return c.VK_ERROR_EXTENSION_NOT_PRESENT;
    return func(device, surface, capabilities);
}

const CreateSwapchainResult = struct {
    swapchain: c.VkSwapchainKHR,
    extent: c.VkExtent2D,
    image_format: c.VkFormat,
};

fn createSwapchain(
    allocator: Allocator,
    instance: c.VkInstance,
    physical_device: c.VkPhysicalDevice,
    logical_device: c.VkDevice,
    surface: c.VkSurfaceKHR,
    window: *c.GLFWwindow,
) !CreateSwapchainResult {
    const swap_capabilities = try getSwapchainCapabilities(
        allocator,
        instance,
        physical_device,
        surface,
    );
    const capabilities = swap_capabilities.capabilities;
    const extent = chooseSwapExtent(window, capabilities);
    const image_count = blk: {
        if (capabilities.maxImageCount == 0) break :blk capabilities.minImageCount + 1;
        break :blk @min(capabilities.minImageCount + 1, capabilities.maxImageCount);
    };

    const indices = try findQueueFamilies(allocator, physical_device, surface);
    if (std.meta.fields(@TypeOf(indices)).len != 2) @compileError("whoops");
    const queues_eq = indices.graphics == indices.present;
    var indices_values = [2]u32{ indices.graphics, indices.present };
    const create_info = c.VkSwapchainCreateInfoKHR{
        .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .surface = surface,
        .minImageCount = image_count,
        .imageFormat = swap_capabilities.format.format,
        .imageColorSpace = swap_capabilities.format.colorSpace,
        .imageExtent = extent,
        .imageArrayLayers = 1,
        .imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .imageSharingMode = if (queues_eq)
            c.VK_SHARING_MODE_EXCLUSIVE
        else
            c.VK_SHARING_MODE_CONCURRENT,
        .queueFamilyIndexCount = if (queues_eq) 0 else 2,
        .pQueueFamilyIndices = if (queues_eq) null else &indices_values,
        .preTransform = capabilities.currentTransform,
        .compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        .presentMode = swap_capabilities.present_mode,
        .clipped = c.VK_TRUE,
        .oldSwapchain = @ptrCast(c.VK_NULL_HANDLE),
    };

    var swapchain: c.VkSwapchainKHR = undefined;
    if (c.vkCreateSwapchainKHR(logical_device, &create_info, null, &swapchain) != c.VK_SUCCESS) {
        return error.FailedToCreateSwapchain;
    }
    return .{
        .swapchain = swapchain,
        .extent = extent,
        .image_format = swap_capabilities.format.format,
    };
}

const SwapChainInfo = struct {
    image_format: c.VkFormat,
    extent: c.VkExtent2D,
};

fn getSwapchainImages(
    allocator: Allocator,
    device: c.VkDevice,
    swapchain: c.VkSwapchainKHR,
) ![]c.VkImage {
    var image_count: u32 = undefined;
    if (c.vkGetSwapchainImagesKHR(device, swapchain, &image_count, null) != c.VK_SUCCESS) {
        return error.FailedToGetSwapchainImages;
    }
    const images = try allocator.alloc(c.VkImage, image_count);
    errdefer allocator.free(images);
    if (c.vkGetSwapchainImagesKHR(device, swapchain, &image_count, images.ptr) != c.VK_SUCCESS) {
        return error.FailedToGetSwapchainImages;
    }

    return images;
}

fn createImageViews(
    allocator: Allocator,
    device: c.VkDevice,
    images: []const c.VkImage,
    format: c.VkFormat,
) ![]c.VkImageView {
    const image_views = try allocator.alloc(c.VkImageView, images.len);
    errdefer allocator.free(image_views);

    for (image_views, 0..) |*image_view, i| {
        const create_info = c.VkImageViewCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = images[i],
            .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
            .format = format,
            .components = .{
                .r = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .g = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .b = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .a = c.VK_COMPONENT_SWIZZLE_IDENTITY,
            },
            .subresourceRange = .{
                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };
        if (c.vkCreateImageView(device, &create_info, null, image_view) != c.VK_SUCCESS) {
            return error.FailedToCreateImageView;
        }
    }
    return image_views;
}

const CreateGraphicsPipelineResult = struct {
    layout: c.VkPipelineLayout,
    pipeline: c.VkPipeline,
};

fn createGraphicsPipeline(
    logical_device: c.VkDevice,
    extent: c.VkExtent2D,
    vert_module: c.VkShaderModule,
    frag_module: c.VkShaderModule,
) !CreateGraphicsPipelineResult {
    const vert_shader_stage_info = c.VkPipelineShaderStageCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = c.VK_SHADER_STAGE_VERTEX_BIT,
        .module = vert_module,
        .pName = "main",
    };
    const frag_shader_stage_info = c.VkPipelineShaderStageCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT,
        .module = frag_module,
        .pName = "main",
    };

    const shader_stages = [_]c.VkPipelineShaderStageCreateInfo{ vert_shader_stage_info, frag_shader_stage_info };

    const dynamic_states = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };

    const dynamic_state_create_info = c.VkPipelineDynamicStateCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .dynamicStateCount = dynamic_states.len,
        .pDynamicStates = &dynamic_states,
    };

    const vertex_input_create_info = c.VkPipelineVertexInputStateCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    };

    const input_assembly_create_info = c.VkPipelineInputAssemblyStateCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        .primitiveRestartEnable = c.VK_FALSE,
    };

    const viewport = c.VkViewport{
        .x = 0.0,
        .y = 0.0,
        .width = @floatFromInt(extent.width),
        .height = @floatFromInt(extent.height),
        .minDepth = 0.0,
        .maxDepth = 1.0,
    };

    const scissor = c.VkRect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = extent,
    };

    const viewport_state_create_info = c.VkPipelineViewportStateCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .viewportCount = 1,
        .pViewports = @ptrCast(&viewport),
        .scissorCount = 1,
        .pScissors = @ptrCast(&scissor),
    };

    const rasterizer_create_info = c.VkPipelineRasterizationStateCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .depthClampEnable = c.VK_FALSE,
        .polygonMode = c.VK_POLYGON_MODE_FILL,
        .lineWidth = 1.0,
        .cullMode = c.VK_CULL_MODE_BACK_BIT,
        .frontFace = c.VK_FRONT_FACE_CLOCKWISE,
        .depthBiasEnable = c.VK_FALSE,
    };

    const multisampling_create_info = c.VkPipelineMultisampleStateCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .sampleShadingEnable = c.VK_FALSE,
        .rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT,
    };

    const color_blend_attachment = c.VkPipelineColorBlendAttachmentState{
        .colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT |
            c.VK_COLOR_COMPONENT_G_BIT |
            c.VK_COLOR_COMPONENT_B_BIT |
            c.VK_COLOR_COMPONENT_A_BIT,
        .blendEnable = c.VK_FALSE,
    };

    const color_blending_create_info = c.VkPipelineColorBlendStateCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .logicOpEnable = c.VK_FALSE,
        .attachmentCount = 1,
        .pAttachments = @ptrCast(&color_blend_attachment),
    };

    const pipeline_layout_create_info = c.VkPipelineLayoutCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
    };

    var pipeline_layout: c.VkPipelineLayout = undefined;
    if (c.vkCreatePipelineLayout(
        logical_device,
        &pipeline_layout_create_info,
        null,
        &pipeline_layout,
    ) != c.VK_SUCCESS) {
        return error.FailedToCreatePipelineLayout;
    }

    const pipeline_create_info = c.VkGraphicsPipelineCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .stageCount = 2,
        .pStages = &shader_stages,
        .pVertexInputState = &vertex_input_create_info,
        .pInputAssemblyState = &input_assembly_create_info,
        .pViewportState = &viewport_state_create_info,
        .pRasterizationState = &rasterizer_create_info,
        .pMultisampleState = &multisampling_create_info,
        .pDepthStencilState = null,
        .pColorBlendState = &color_blending_create_info,
        .pDynamicState = &dynamic_state_create_info,
        .layout = pipeline_layout,
        .renderPass = null,
        .subpass = 0,
    };

    var pipeline: c.VkPipeline = undefined;
    if (c.vkCreateGraphicsPipelines(
        logical_device,
        @ptrCast(c.VK_NULL_HANDLE),
        1,
        &pipeline_create_info,
        null,
        &pipeline,
    ) != c.VK_SUCCESS) {
        return error.FailedToCreateGraphicsPipeline;
    }

    return .{
        .layout = pipeline_layout,
        .pipeline = pipeline,
    };
}

fn createShaderModule(
    allocator: Allocator,
    logical_device: c.VkDevice,
    code_path: []const u8,
) !c.VkShaderModule {
    const f = try std.fs.cwd().openFile(code_path, .{});
    defer f.close();

    const stat = try f.stat();
    const code = try allocator.alloc(u32, @divExact(stat.size, 4));
    defer allocator.free(code);

    _ = try f.readAll(std.mem.sliceAsBytes(code));

    const create_info = c.VkShaderModuleCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = code.len * 4,
        .pCode = @ptrCast(code.ptr),
    };

    var shader_module: c.VkShaderModule = undefined;
    if (c.vkCreateShaderModule(logical_device, &create_info, null, &shader_module) != c.VK_SUCCESS) {
        return error.FailedToCreateShaderModule;
    }
    return shader_module;
}
